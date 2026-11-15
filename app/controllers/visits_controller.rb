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
    @visit.confirmed_by = Current.user unless @visit.pending?
    @visit.assign_attributes(recorded_at: Time.current, recorded_at_source: "server") if @visit.receipt_version == 1 && !@visit.pending? && @visit.recorded_at.nil?
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
      @visit.with_lock do
        @visit.assign_attributes(execution_params)
        @visit.confirmed_by = Current.user if @visit.status_in_database == "pending" && !@visit.pending?
        @visit.assign_attributes(recorded_at: Time.current, recorded_at_source: "server") if @visit.receipt_version == 1 && !@visit.pending? && @visit.recorded_at.nil?
        @visit.save.tap do |success|
          if success && !@visit.pending? && (@delivery_run.assigned? || @delivery_run.in_progress?)
            @delivery_run.update!(status: @delivery_run.visits.pending.exists? ? :in_progress : :completed)
          end
        end
      end
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
    params.expect(visit: [ :customer_id, :position, :status, :notes, :failure_reason, :receipt_version,
      delivery_items_attributes: [ [ :id, :product_id, :description, :unit, :planned_quantity, :delivered_quantity, :notes, :_destroy ] ] ])
  end
end
