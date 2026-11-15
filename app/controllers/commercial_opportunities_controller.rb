class CommercialOpportunitiesController < WorkflowManagementController
  before_action :workflow_options

  def index
    relation = Current.company.commercial_opportunities
    %w[status rule customer_id product_id].each { |field| relation = relation.where(field => params[field]) if params[field].present? }
    @opportunities = paginate(relation.order(detected_at: :desc, id: :desc))
  end

  def show
    @opportunity = Current.company.commercial_opportunities.includes(:customer, :product, :delivery_order).find(params[:id])
    @tasks = @opportunity.workflow_tasks.includes(:assignee, :customer).order(id: :desc)
    @events = @opportunity.workflow_events.includes(:user).order(:id)
    customer_ids = Array(@opportunity.evidence["customer_ids"]).map(&:to_i)
    @affected_customers = Current.company.customers.where(id: customer_ids).alphabetical
    order_ids = Array(@opportunity.evidence["order_ids"]).map(&:to_i)
    @orders = Current.company.delivery_orders.where(id: order_ids).order(scheduled_date: :desc)
  end

  def act
    result = workflow_actions.opportunity_action(id: params[:id], operation_id: params[:operation_id], attributes: params.expect(opportunity: [ :action, :version, :message, :assignee_id, :due_at, :snoozed_until ]).to_h)
    redirect_to(result["task_id"] ? workflow_task_path(result["task_id"]) : commercial_opportunity_path(result.fetch("opportunity_id")), notice: "Gestión registrada.", status: :see_other)
  end
end
