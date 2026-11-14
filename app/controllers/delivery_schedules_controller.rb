class DeliverySchedulesController < ManagementController
  before_action :set_customer
  before_action :set_schedule, only: [ :edit, :update ]
  before_action :load_products

  def new
    @delivery_schedule = @customer.delivery_schedules.new(company: Current.company, weekday: 1, starts_on: Current.company.local_date)
    @delivery_schedule.delivery_schedule_items.build
  end

  def create
    @delivery_schedule = @customer.delivery_schedules.new(schedule_params.merge(company: Current.company))
    if @delivery_schedule.save
      redirect_to customer_path(@customer), notice: "Programación creada correctamente.", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @delivery_schedule.update(schedule_params)
      redirect_to customer_path(@customer), notice: "Programación actualizada correctamente.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_customer
    @customer = Current.company.customers.find(params[:customer_id])
  end

  def set_schedule
    @delivery_schedule = @customer.delivery_schedules.find(params[:id])
  end

  def load_products
    existing_ids = @delivery_schedule&.delivery_schedule_items&.pluck(:product_id) || []
    @products = Current.company.products.where(active: true).or(Current.company.products.where(id: existing_ids)).alphabetical
  end

  def schedule_params
    params.expect(delivery_schedule: [ :weekday, :preferred_time, :window_start, :window_end, :starts_on, :ends_on, :active, :notes,
      delivery_schedule_items_attributes: [ [ :id, :product_id, :description, :quantity, :unit, :position, :_destroy ] ] ])
  end
end
