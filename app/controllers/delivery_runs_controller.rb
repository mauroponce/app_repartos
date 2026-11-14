class DeliveryRunsController < ManagementController
  before_action :set_run, only: [ :show, :edit, :update, :add_orders, :remove_order, :reorder ]
  before_action :load_drivers, only: [ :new, :create, :edit, :update, :index ]

  def index
    runs = Current.company.delivery_runs.includes(:driver, visits: [ :delivery_orders, :delivery_items ])
    runs = runs.where(scheduled_date: params[:date]) if params[:date].present?
    runs = runs.where(driver_id: params[:driver_id]) if params[:driver_id].present?
    runs = runs.where(status: params[:status]) if params[:status].present?
    @delivery_runs = paginate(runs.order(scheduled_date: :desc, id: :desc))
  end

  def new
    selected = Current.company.delivery_orders.unplanned.where(id: Array(params[:order_ids]))
    if selected.distinct.count(:scheduled_date) > 1
      return redirect_to delivery_orders_path, alert: "Seleccioná entregas de una misma fecha para crear una hoja de ruta."
    end
    date = params[:date].presence || selected.first&.scheduled_date || Current.company.local_date
    @delivery_run = Current.company.delivery_runs.new(scheduled_date: date, name: "")
    @selected_ids = selected.pluck(:id).map(&:to_s)
    load_available_orders
  end

  def create
    @delivery_run = Current.company.delivery_runs.new(run_params.except(:driver_id))
    @delivery_run.driver = selected_driver
    @delivery_run.status = :draft unless @delivery_run.status.in?(%w[draft assigned])
    @selected_ids = selected_order_ids
    DeliveryRunPlanner.call(company: Current.company, delivery_run: @delivery_run, order_ids: @selected_ids)
    redirect_to delivery_run_path(@delivery_run), notice: "Hoja de ruta creada correctamente.", status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    @delivery_run.errors.add(:base, error.message)
    load_available_orders
    render :new, status: :unprocessable_entity
  end

  def available
    @selected_ids = []
    @delivery_run = Current.company.delivery_runs.new(scheduled_date: params[:date])
    load_available_orders
    render partial: "available_orders"
  end

  def show
    @visits = @delivery_run.visits.includes(:delivery_items, delivery_orders: :delivery_order_items)
    load_available_orders if @delivery_run.editable?
  end

  def edit
  end

  def update
    Current.company.with_lock do
      @delivery_run.reload
      @delivery_run.assign_attributes(run_params.except(:driver_id))
      @delivery_run.driver = selected_driver if run_params.key?(:driver_id)
      @delivery_run.save!
    end
    redirect_to delivery_run_path(@delivery_run), notice: "Hoja de ruta actualizada.", status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    @delivery_run.errors.add(:base, error.message)
    render :edit, status: :unprocessable_entity
  end

  def add_orders
    DeliveryRunPlanner.call(company: Current.company, delivery_run: @delivery_run, order_ids: Array(params[:order_ids]))
    redirect_to delivery_run_path(@delivery_run), notice: "Entregas agregadas.", status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to delivery_run_path(@delivery_run), alert: error.message, status: :see_other
  end

  def remove_order
    DeliveryRunPlanner.remove(company: Current.company, delivery_run: @delivery_run, order_id: params[:order_id])
    redirect_to delivery_run_path(@delivery_run), notice: "Entrega pendiente de planificación nuevamente.", status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to delivery_run_path(@delivery_run), alert: error.message, status: :see_other
  end

  def reorder
    DeliveryRunReorderer.call(company: Current.company, delivery_run: @delivery_run, visit_ids: params[:visit_ids])
    redirect_to delivery_run_path(@delivery_run), notice: "Orden de paradas actualizado.", status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to delivery_run_path(@delivery_run), alert: error.message, status: :see_other
  end

  private

  def set_run
    @delivery_run = Current.company.delivery_runs.find(params[:id])
  end

  def load_available_orders
    @available_orders = Current.company.delivery_orders.unplanned.where(scheduled_date: @delivery_run.scheduled_date).includes(:delivery_order_items).order(:preferred_time, :id)
  end

  def load_drivers
    directory = Current.company.users.driver
    @drivers = directory.active
    @drivers = @drivers.or(directory.where(id: @delivery_run.driver_id)) if @delivery_run&.driver_id
    @drivers = @drivers.alphabetical
  end

  def selected_driver
    @drivers.find(run_params[:driver_id]) if run_params[:driver_id].present?
  end

  def selected_order_ids
    selected = Array(params[:order_ids]).reject(&:blank?).map(&:to_s).uniq
    ordered = Array(params[:ordered_order_ids]).reject(&:blank?).map(&:to_s)
    return selected if ordered.empty?
    raise ArgumentError, "La selección cambió; revisá las entregas y su orden" unless selected.sort == ordered.sort
    ordered
  end

  def run_params
    params.expect(delivery_run: [ :name, :scheduled_date, :driver_id, :status ])
  end
end
