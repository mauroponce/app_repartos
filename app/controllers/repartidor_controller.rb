class RepartidorController < ApplicationController
  include DriverDashboard
  layout "repartidor"
  before_action :require_driver
  around_action :use_company_time_zone
  before_action :prevent_caching
  rescue_from DriverOperationSync::Unauthorized, with: :request_authentication

  def index
    DriverWorkSnapshot.consistent_read do
      load_dashboard
      render :index
    end
  end

  def upcoming
    @run = assigned_runs.where(status: %w[assigned in_progress completed]).find(params[:id])
    @visits = @run.visits.includes(:delivery_items, :delivery_orders)
  end

  def scheduled
    today = Current.company.local_date
    @upcoming_runs = assigned_runs.where(scheduled_date: (today + 1)..(today + 14), status: %w[assigned in_progress]).order(:scheduled_date, :id).limit(30)
  end

  def update
    @submitted = visit_params.to_h.deep_symbolize_keys
    visit = DriverVisitRecorder.call(user: Current.user, visit_id: params[:id], attributes: @submitted)
    redirect_to repartidor_root_path(run_id: visit.delivery_run_id), notice: "Visita registrada correctamente.", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid, DriverVisitRecorder::Conflict => error
    @recording_error = error.message
    @invalid_visit_id = params[:id].to_i
    DriverWorkSnapshot.consistent_read do
      run = assigned_runs.joins(:visits).find_by!(visits: { id: params[:id] })
      visible = run.scheduled_date == Current.company.local_date && run.status.in?(%w[assigned in_progress completed])
      load_dashboard(run_id: visible ? run.id : nil)
      render :index, status: error.is_a?(DriverVisitRecorder::Conflict) ? :conflict : :unprocessable_entity
    end
  end

  private

  def require_driver
    redirect_to admin_root_path unless Current.user.driver?
  end

  def use_company_time_zone(&action)
    Time.use_zone(Current.company.time_zone, &action)
  end

  def prevent_caching
    response.headers["Cache-Control"] = "no-store"
  end

  def visit_params
    params.expect(visit: [ :status, :notes, items: [ [ :id, :delivered_quantity ] ] ])
  end
end
