class DeliveryOrdersController < ManagementController
  before_action :set_order, only: [ :show, :edit, :update, :cancel ]
  before_action :load_options, only: [ :new, :create, :edit, :update ]

  def index
    orders = Current.company.delivery_orders.includes(:delivery_order_items, visit: :delivery_run)
    orders = orders.where(scheduled_date: params[:date]) if params[:date].present?
    orders = orders.where(customer_id: params[:customer_id]) if params[:customer_id].present?
    orders = orders.where(visit_id: Current.company.visits.where(delivery_run_id: params[:delivery_run_id]).select(:id)) if params[:delivery_run_id].present?
    orders = case params[:status]
    when "unplanned" then orders.unplanned
    when "assigned" then orders.pending.where.not(visit_id: nil)
    when "pending", "completed", "cancelled" then orders.where(status: params[:status])
    else orders
    end
    if params[:q].present?
      orders = orders.where("delivery_orders.customer_name ILIKE :q OR EXISTS (SELECT 1 FROM delivery_order_items WHERE delivery_order_items.delivery_order_id = delivery_orders.id AND delivery_order_items.description ILIKE :q)", q: "%#{DeliveryOrder.sanitize_sql_like(params[:q].strip)}%")
    end
    @delivery_orders = paginate(orders.order(:scheduled_date, :preferred_time, :id))
    @customers = Current.company.customers.alphabetical
    @runs = Current.company.delivery_runs.order(scheduled_date: :desc, id: :desc)
  end

  def new
    @delivery_order = Current.company.delivery_orders.new(scheduled_date: Current.company.local_date)
    @delivery_order.delivery_order_items.build
  end

  def create
    @delivery_order = Current.company.delivery_orders.new(order_params)
    if @delivery_order.save
      redirect_to delivery_order_path(@delivery_order), notice: "Entrega creada. Ya podés incluirla en una hoja de ruta.", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @items = @delivery_order.delivery_order_items.includes(:delivery_item)
  end

  def edit
    redirect_to delivery_order_path(@delivery_order), alert: "La entrega ya no admite cambios." unless @delivery_order.editable?
  end

  def update
    DeliveryOrderEditor.call(order: @delivery_order, attributes: order_params)
    redirect_to delivery_order_path(@delivery_order), notice: "Entrega actualizada.", status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    @delivery_order.errors.add(:base, error.message)
    render :edit, status: :unprocessable_entity
  end

  def cancel
    DeliveryOrderEditor.call(order: @delivery_order, cancel: true)
    redirect_to delivery_order_path(@delivery_order), notice: "Entrega cancelada.", status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to delivery_order_path(@delivery_order), alert: error.message, status: :see_other
  end

  def generate
    date = Date.iso8601(params[:date].to_s)
    orders = DeliveryOrderGenerator.call(company: Current.company, date: date)
    redirect_to delivery_orders_path(date: date), notice: "Programaciones procesadas: #{orders.size} entregas recurrentes para la fecha. Los reintentos conservan las existentes.", status: :see_other
  rescue Date::Error, ActiveRecord::RecordInvalid => error
    redirect_to delivery_orders_path, alert: "No se pudieron generar las entregas: #{error.message}", status: :see_other
  end

  private

  def set_order
    @delivery_order = Current.company.delivery_orders.find(params[:id])
  end

  def load_options
    @customers = Current.company.customers.alphabetical
    ids = @delivery_order ? @delivery_order.delivery_order_items.pluck(:product_id) : []
    @products = Current.company.products.active.or(Current.company.products.where(id: ids)).alphabetical
  end

  def order_params
    params.expect(delivery_order: [ :customer_id, :scheduled_date, :preferred_time, :window_start, :window_end, :notes,
      delivery_order_items_attributes: [ [ :id, :product_id, :description, :quantity, :unit, :position, :_destroy ] ] ])
  end
end
