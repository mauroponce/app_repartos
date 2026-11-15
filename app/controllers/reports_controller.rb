class ReportsController < WorkflowManagementController
  before_action :workflow_options

  def show
    @filter = ReportFilter.new(Current.company, params.permit(:period, :start_on, :end_on, :driver_id, :customer_id, :run_id, :product_id).to_h)
    @report = DeliveryReports.new(@filter)
    @counts = @report.counts
    @previous = DeliveryReports.new(@filter.previous).counts
    @daily = @report.daily
    @shortages = @report.shortages
    @drivers = @report.drivers
    @problematic = @report.problematic_customers
    @ranking = @report.incident_ranking
    @details = @report.details(outcome: params[:outcome], page: params[:page])
    @products = Current.company.products.alphabetical.limit(30).to_a
    if @filter.product_id
      selected = Current.company.products.find(@filter.product_id)
      @products << selected unless @products.any? { |product| product.id == selected.id }
    end
    relation = Current.company.commercial_opportunities
    relation = relation.where(customer_id: @filter.customer_id) if @filter.customer_id
    relation = relation.where(product_id: @filter.product_id) if @filter.product_id
    relation = relation.where(status: params[:alert_status].presence_in(CommercialOpportunity::STATUSES.keys) || "open")
    @opportunities = relation.includes(:customer, :product, :delivery_order).order(detected_at: :desc, id: :desc).limit(20)
  end

  def refresh
    CommercialOpportunitiesJob.perform_later(Current.company.id, force: true)
    ReconcileDeliveryIncidentsJob.perform_later(Current.company.id)
    redirect_to reports_path, notice: "Análisis solicitado. Las oportunidades se actualizarán en segundo plano.", status: :see_other
  end
end
