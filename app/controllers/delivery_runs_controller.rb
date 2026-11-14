class DeliveryRunsController < ManagementController
  before_action :set_run, only: [ :show, :edit, :update, :generate ]
  before_action :load_drivers, only: [ :new, :create, :edit, :update ]

  def index
    @delivery_runs = paginate(Current.company.delivery_runs.includes(:driver).order(scheduled_date: :desc, id: :desc))
  end

  def new
    @delivery_run = Current.company.delivery_runs.new(scheduled_date: Current.company.local_date, name: "Reparto")
  end

  def create
    @delivery_run = Current.company.delivery_runs.new(run_params.except(:driver_id))
    @delivery_run.driver = selected_driver
    @delivery_run.status = :assigned if @delivery_run.driver && @delivery_run.draft?
    if @delivery_run.valid?
      if params[:generate_schedules] == "1"
        @delivery_run = DeliveryRunGenerator.call(company: Current.company, date: @delivery_run.scheduled_date, driver: @delivery_run.driver, name: @delivery_run.name)
      else
        @delivery_run.save!
      end
      redirect_to delivery_run_path(@delivery_run), notice: "Reparto creado correctamente.", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid => error
    @delivery_run.errors.add(:base, error.message)
    render :new, status: :unprocessable_entity
  end

  def show
    @visits = @delivery_run.visits.includes(:delivery_items)
  end

  def edit
  end

  def update
    @delivery_run.assign_attributes(run_params.except(:driver_id))
    @delivery_run.driver = selected_driver
    if @delivery_run.save
      redirect_to delivery_run_path(@delivery_run), notice: "Reparto actualizado correctamente.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def generate
    DeliveryRunGenerator.call(company: Current.company, date: @delivery_run.scheduled_date, delivery_run: @delivery_run)
    redirect_to delivery_run_path(@delivery_run), notice: "Se agregaron las programaciones aplicables sin duplicar visitas existentes.", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    redirect_to delivery_run_path(@delivery_run), alert: error.message, status: :see_other
  end

  private

  def set_run
    @delivery_run = Current.company.delivery_runs.find(params[:id])
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

  def run_params
    params.expect(delivery_run: [ :name, :scheduled_date, :driver_id, :status ])
  end
end
