class CustomersController < ApplicationController
  before_action :require_customer_management
  before_action :set_filters, only: [ :index, :autocomplete ]
  before_action :set_customer, only: [ :show, :edit, :update ]

  def index
    directory = Current.company.customers
    @total = directory.count
    @active = directory.active.count
    @cities = directory.distinct.count(:city)
    @inactive = directory.inactive.count
    filtered = filtered_customers
    @filtered_count = filtered.count
    @pages = [ (@filtered_count / 12.0).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    @customers = filtered.limit(12).offset((@page - 1) * 12)
  end

  def autocomplete
    response.headers["Cache-Control"] = "private, no-store"
    matches = @query.present? ? filtered_customers.limit(8).pluck(:name, :contact, :city) : []
    render json: matches.map { |name, contact, city| { name: name, contact: contact, city: city } }
  end

  def new
    @customer = Current.company.customers.new
  end

  def create
    @customer = Current.company.customers.new(customer_params)
    if @customer.save(context: :geocoded)
      redirect_to customers_path, notice: "Cliente creado correctamente.", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @delivery_schedules = @customer.delivery_schedules.includes(:delivery_schedule_items).order(:weekday, :preferred_time, :id)
  end

  def edit
  end

  def update
    @customer.assign_attributes(customer_params)
    if @customer.save(context: :geocoded)
      redirect_to customer_path(@customer), notice: "Cliente actualizado correctamente.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_filters
    @query = params[:q].to_s.strip.first(120)
    @status = params[:status].presence_in(Customer.statuses.keys)
  end

  def filtered_customers
    scope = Current.company.customers.alphabetical
    scope = scope.search(@query) if @query.present?
    scope = scope.where(status: @status) if @status
    scope
  end

  def set_customer
    @customer = Current.company.customers.find(params[:id])
  end

  def require_customer_management
    render "errors/forbidden", status: :forbidden unless Current.user.manages_customers?
  end

  def customer_params
    params.expect(customer: [ :name, :contact, :phone, :email, :address, :city, :status, :latitude, :longitude, :location_confirmed ])
  end
end
