class VisitsController < ManagementController
  before_action :set_run
  before_action :set_visit, only: [ :edit, :update ]
  before_action :load_options

  def new
    @visit = @delivery_run.visits.new(company: Current.company, position: @delivery_run.visits.maximum(:position).to_i + 1)
    @visit.delivery_items.build
  end

  def create
    @visit = @delivery_run.visits.new(visit_params.except(:customer_id).merge(company: Current.company))
    @visit.customer = Current.company.customers.find(visit_params[:customer_id]) if visit_params[:customer_id].present?
    unless @delivery_run.editable?
      @visit.errors.add(:base, "La hoja ya no admite paradas manuales")
      return render :new, status: :unprocessable_entity
    end
    saved = Current.company.with_lock do
      @delivery_run.reload
      @visit.position = @delivery_run.visits.maximum(:position).to_i + 1 if visit_params[:position].blank?
      @delivery_run.editable? && @visit.save
    end
    if saved
      redirect_to delivery_run_path(@delivery_run), notice: "Visita agregada correctamente.", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    saved = Current.company.with_lock do
      @delivery_run.reload
      @visit.with_lock { @visit.update(execution_params) }
    end
    if saved
      redirect_to delivery_run_path(@delivery_run), notice: "Visita y cantidades guardadas correctamente.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_run
    @delivery_run = Current.company.delivery_runs.find(params[:delivery_run_id])
  end

  def set_visit
    @visit = @delivery_run.visits.find(params[:id])
  end

  def load_options
    @customers = Current.company.customers.alphabetical
    existing_ids = @visit&.delivery_items&.pluck(:product_id) || []
    @products = Current.company.products.active.or(Current.company.products.where(id: existing_ids)).alphabetical
  end

  def execution_params
    attributes = visit_params.except(:customer_id)
    return attributes if @visit.delivery_orders.empty?
    # Order-backed merchandise is edited through its order; execution may only
    # record quantities and notes for existing items.
    nested = attributes[:delivery_items_attributes]
    rows = nested.is_a?(Array) ? nested : nested&.values
    if rows
      attributes[:delivery_items_attributes] = rows.map do |row|
        raise ActiveRecord::RecordNotFound unless @visit.delivery_items.exists?(id: row[:id])
        row.slice(:id, :delivered_quantity, :notes)
      end
    end
    attributes
  end

  def visit_params
    params.expect(visit: [ :customer_id, :position, :status, :notes,
      delivery_items_attributes: [ [ :id, :product_id, :description, :unit, :planned_quantity, :delivered_quantity, :notes, :_destroy ] ] ])
  end
end
