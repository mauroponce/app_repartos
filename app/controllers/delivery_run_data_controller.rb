class DeliveryRunDataController < ManagementController
  before_action :set_run
  rescue_from ArgumentError, ActiveRecord::RecordInvalid, with: :invalid_record

  def show
    @costs = @run.delivery_run_costs.includes(:user, :reversal).order(:id)
    @movements = @run.run_stock_movements.includes(:user).order(:id)
    @stock = RunStockBalance.call(@run)
    @products = Current.company.products.active.alphabetical
    @valuation = DeliveryValuation.new(@run.visits.includes(:delivery_items).flat_map(&:delivery_items))
    @metrics = DeliveryMetrics.call(@run.delivery_orders.includes(delivery_order_items: :delivery_item).to_a)
    @events = Current.company.delivery_status_events.where(delivery_run_id: @run.id)
      .or(Current.company.delivery_status_events.where(visit_id: @run.visits.select(:id)))
      .or(Current.company.delivery_status_events.where("context @> ?", { run_id: @run.id }.to_json))
      .or(Current.company.delivery_status_events.where(delivery_order_id: @run.delivery_orders.select(:id))).includes(:user).order(:id)
  end

  def create_cost
    RunCostRecorder.call(user: Current.user, run_id: @run.id, attributes: params.expect(cost: [ :operation_id, :category, :description, :vehicle_label, :amount, :estimated ]).to_h)
    redirect_to delivery_run_data_path(@run), notice: "Costo registrado.", status: :see_other
  end

  def reverse_cost
    RunCostRecorder.reverse(user: Current.user, run_id: @run.id, cost_id: params[:cost_id])
    redirect_to delivery_run_data_path(@run), notice: "Anulación registrada; el costo original conserva su historial.", status: :see_other
  end

  def close_costs
    RunCostRecorder.close(user: Current.user, run_id: @run.id)
    redirect_to delivery_run_data_path(@run), notice: "Costos cerrados.", status: :see_other
  end

  def create_stock
    RunStockRecorder.call(user: Current.user, run_id: @run.id, attributes: params.expect(movement: [ :operation_id, :kind, :product_id, :description, :unit, :quantity, :reason ]).to_h)
    redirect_to delivery_run_data_path(@run), notice: "Movimiento registrado.", status: :see_other
  end

  private

  def set_run
    @run = Current.company.delivery_runs.find(params[:delivery_run_id])
    response.headers["Cache-Control"] = "no-store"
  end

  def invalid_record(error)
    redirect_to delivery_run_data_path(@run), alert: error.message, status: :see_other
  end
end
