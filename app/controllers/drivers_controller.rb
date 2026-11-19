class DriversController < ManagementController
  before_action :set_filters, only: [ :index, :autocomplete ]
  before_action :set_driver, only: [ :show, :edit, :update, :destroy ]

  def index
    directory = Current.company.users.driver
    @total = directory.count
    @active = directory.active.count
    @inactive = directory.inactive.count
    @assigned = Current.company.delivery_runs.where(status: [ :assigned, :in_progress ]).distinct.count(:driver_id)
    sort_columns = { "name" => 'LOWER(users.name) COLLATE "es-x-icu"', "email" => 'LOWER(users.email_address) COLLATE "es-x-icu"', "phone" => 'LOWER(users.phone) COLLATE "es-x-icu"', "runs" => "(SELECT COUNT(*) FROM delivery_runs WHERE delivery_runs.driver_id = users.id AND delivery_runs.company_id = users.company_id)", "status" => "users.status" }
    @sort = params[:sort].presence_in(sort_columns.keys) || "name"
    @direction = params[:direction] == "desc" ? "desc" : "asc"
    filtered = filtered_drivers.reorder(Arel.sql("#{sort_columns.fetch(@sort)} #{@direction.upcase} NULLS LAST"), :id)
    @filtered_count = filtered.count
    @pages = [ (@filtered_count / 25.0).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    @drivers = filtered.limit(25).offset((@page - 1) * 25)
    @run_counts = Current.company.delivery_runs.where(driver_id: @drivers.map(&:id)).group(:driver_id).count
  end

  def autocomplete
    response.headers["Cache-Control"] = "private, no-store"
    matches = @query.present? ? filtered_drivers.limit(8).pluck(:name, :email_address, :phone) : []
    render json: matches.map { |name, email, phone| { name: name, contact: email, city: phone } }
  end

  def new
    @driver = Current.company.users.driver.new
  end

  def create
    @driver = Current.company.users.new(driver_params.merge(role: :driver))
    if @driver.save
      redirect_to drivers_path, notice: "Repartidor creado correctamente.", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @delivery_runs = @driver.delivery_runs.order(scheduled_date: :desc, id: :desc).limit(5)
  end

  def edit
  end

  def update
    attributes = driver_params
    attributes = attributes.except(:password, :password_confirmation) if attributes[:password].blank? && attributes[:password_confirmation].blank?
    if @driver.update(attributes)
      redirect_to driver_path(@driver), notice: "Repartidor actualizado correctamente.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @driver.destroy
      redirect_to drivers_path, notice: "Repartidor eliminado correctamente.", status: :see_other
    else
      redirect_to driver_path(@driver), alert: "No se puede eliminar un repartidor con repartos asociados. Podés cambiar su estado a inactivo.", status: :see_other
    end
  rescue ActiveRecord::InvalidForeignKey
    redirect_to driver_path(@driver), alert: "El repartidor tiene repartos asociados. Podés cambiar su estado a inactivo.", status: :see_other
  end

  private

  def set_filters
    @query = params[:q].to_s.strip.first(120)
    @status = if action_name == "index" && !params.key?(:status)
      "active"
    else
      params[:status].presence_in(User.statuses.keys)
    end
  end

  def filtered_drivers
    scope = Current.company.users.driver.alphabetical
    scope = scope.search(@query) if @query.present?
    scope = scope.where(status: @status) if @status
    scope
  end

  def set_driver
    @driver = Current.company.users.driver.find(params[:id])
  end

  def driver_params
    params.expect(driver: [ :name, :email_address, :phone, :status, :password, :password_confirmation ])
  end
end
