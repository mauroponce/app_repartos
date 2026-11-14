class RepartidorController < ApplicationController
  layout "repartidor"
  before_action :require_driver
  around_action :use_company_time_zone
  before_action :prevent_caching

  def index
    load_dashboard
  end

  def update
    @submitted = visit_params.to_h.deep_symbolize_keys
    visit = DriverVisitRecorder.call(user: Current.user, visit_id: params[:id], attributes: @submitted)
    redirect_to repartidor_root_path(run_id: visit.delivery_run_id), notice: "Visita registrada correctamente.", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid, DriverVisitRecorder::Conflict => error
    @recording_error = error.message
    @invalid_visit_id = params[:id].to_i
    run = assigned_runs.joins(:visits).find_by!(visits: { id: params[:id] })
    visible = run.scheduled_date == Current.company.local_date && run.status.in?(%w[assigned in_progress completed])
    load_dashboard(run_id: visible ? run.id : nil)
    render :index, status: error.is_a?(DriverVisitRecorder::Conflict) ? :conflict : :unprocessable_entity
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

  def assigned_runs
    Current.company.delivery_runs.where(driver_id: Current.user.id)
  end

  def load_dashboard(run_id: params[:run_id])
    @today = Current.company.local_date
    @runs = assigned_runs.where(scheduled_date: @today, status: %w[assigned in_progress completed]).order(:id).to_a
    @run = run_id.present? ? @runs.find { |run| run.id.to_s == run_id.to_s } : (@runs.find { |run| !run.completed? } || @runs.first)
    raise ActiveRecord::RecordNotFound if run_id.present? && !@run
    @visits = @run ? @run.visits.includes(:customer, :delivery_items, :delivery_schedule, :delivery_orders).to_a : []
    @next_visit = @visits.find(&:pending?)
    @resolved_count = @visits.count { |visit| !visit.pending? }
    @completed_count = @visits.count(&:completed?)
    @progress = @visits.empty? ? 0 : (@resolved_count * 100.0 / @visits.size).round
    @markers = @visits.filter_map do |visit|
      next unless visit.customer.latitude && visit.customer.longitude
      { id: visit.id, position: visit.position, name: visit.customer_name, latitude: visit.customer.latitude.to_f,
        longitude: visit.customer.longitude.to_f, status: visit.status, current: visit == @next_visit }
    end
    week = @today.beginning_of_week..@today.end_of_week
    completed = Current.company.visits.joins(:delivery_run).where(delivery_runs: { driver_id: Current.user.id }).completed
    zone_name = Time.zone.tzinfo.identifier
    @week_counts = completed.where(completed_at: week.first.beginning_of_day..week.last.end_of_day)
      .group("DATE(completed_at AT TIME ZONE 'UTC' AT TIME ZONE #{ActiveRecord::Base.connection.quote(zone_name)})").count
    @history = Current.company.visits.joins(:delivery_run).where(delivery_runs: { driver_id: Current.user.id })
      .where.not(status: :pending).order(updated_at: :desc).limit(10)
  end

  def visit_params
    params.expect(visit: [ :status, :notes, items: [ [ :id, :delivered_quantity ] ] ])
  end
end
