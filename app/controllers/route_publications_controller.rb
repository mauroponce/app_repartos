class RoutePublicationsController < ManagementController
  before_action :set_run
  rescue_from Osrm::Client::Error, ArgumentError, ActiveRecord::RecordInvalid, with: :invalid_request

  def create
    RoutePublication.request!(user: Current.user, run: @run, settings: params.fetch(:optimization, ActionController::Parameters.new).permit(:origin, :departure, :return_to_depot).to_h)
    redirect_to delivery_run_path(@run), notice: "Confirmación recibida. El recorrido se prepara en segundo plano y se publicará cuando esté listo.", status: :see_other
  end

  def show
    publication = @run.route_publication
    render json: { state: publication&.stalled? ? "failed" : publication&.state || "manual", updated_at: publication&.updated_at&.iso8601(6), location: delivery_run_path(@run) }
  end

  def manual
    RoutePublication.use_manual!(user: Current.user, run: @run)
    redirect_to delivery_run_path(@run), notice: "Hoja publicada con el orden manual. No se ejecutarán cambios automáticos pendientes.", status: :see_other
  end

  private

  def set_run
    @run = Current.company.delivery_runs.find(params[:delivery_run_id])
    response.headers["Cache-Control"] = "no-store"
  end

  def invalid_request(error)
    redirect_to delivery_run_path(@run), alert: error.message, status: :see_other
  end
end
