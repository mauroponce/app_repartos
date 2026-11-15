class RouteOptimizationProposalsController < ManagementController
  before_action :set_run
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  rescue_from ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError, Osrm::Client::Error, with: :invalid_proposal

  def new
    @problem = RouteOptimization::Problem.new(@run)
  end

  def create
    proposal = RouteOptimizationProposal.request!(user: Current.user, run: @run, settings: params.fetch(:optimization, ActionController::Parameters.new).permit(:origin, :departure, :return_to_depot).to_h)
    redirect_to delivery_run_optimization_proposal_path(@run, proposal), status: :see_other
  end

  def show
    @proposal = @run.route_optimization_proposals.find(params[:id])
    @visits = @run.visits.index_by(&:id)
    @expired = @proposal.expires_at <= Time.current && @proposal.status != "applied"
    respond_to do |format|
      format.html
      format.json { render json: { status: @expired ? "expired" : @proposal.status, location: delivery_run_optimization_proposal_path(@run, @proposal) } }
    end
  end

  def apply
    proposal = @run.route_optimization_proposals.find(params[:id])
    proposal.apply!(user: Current.user)
    redirect_to delivery_run_path(@run), notice: "Orden confirmado. Los pedidos y cantidades se conservaron.", status: :see_other
  end

  def destroy
    Current.company.with_lock do
      proposal = @run.route_optimization_proposals.find(params[:id])
      raise ArgumentError, "Una propuesta aplicada conserva su historial" if proposal.status == "applied"
      proposal.update!(status: "discarded")
      proposal.fail_publication!("Optimización descartada. Revisá la hoja, volvé a confirmar o publicá el orden manual.")
    end
    redirect_to delivery_run_path(@run), notice: "Propuesta descartada. Se conservó el orden de la hoja.", status: :see_other
  end

  private

  def set_run
    @run = Current.company.delivery_runs.find(params[:delivery_run_id])
  end

  def invalid_proposal(error)
    redirect_to delivery_run_path(@run), alert: error.message, status: :see_other
  end
end
