class WorkflowTasksController < WorkflowManagementController
  before_action :workflow_options

  def index
    relation = Current.company.workflow_tasks.includes(:assignee, :customer, :creator)
    %w[category priority status assignee_id customer_id incident_id].each { |field| relation = relation.where(field => params[field]) if params[field].present? }
    relation = relation.unfinished.where("due_at < ?", Time.current) if params[:overdue] == "1"
    @tasks = paginate(relation.order(Arel.sql("closed_at ASC NULLS FIRST, due_at ASC NULLS LAST"), id: :desc))
    @notices = Current.company.internal_notices.where(user: Current.user, read_at: nil).order(id: :desc).limit(10)
  end

  def new
    @task = Current.company.workflow_tasks.new(category: "administrative", priority: "normal")
  end

  def create
    result = workflow_actions.create_task(operation_id: params[:operation_id], attributes: params.expect(task: [ :title, :description, :category, :priority, :assignee_id, :due_at, :customer_id, :visit_id, :delivery_run_id, :delivery_order_id, :incident_id ]).to_h)
    redirect_to workflow_task_path(result.fetch("task_id")), notice: "Tarea creada.", status: :see_other
  end

  def show
    @task = Current.company.workflow_tasks.includes(:assignee, :creator, :customer, :delivery_order, :incident, :commercial_opportunity).find(params[:id])
    @events = @task.workflow_events.includes(:user).order(:id)
  end

  def update
    result = workflow_actions.update_task(id: params[:id], operation_id: params[:operation_id], attributes: params.expect(task: [ :action, :version, :title, :description, :priority, :assignee_id, :due_at, :result ]).to_h)
    redirect_to workflow_task_path(result.fetch("task_id")), notice: "Acción registrada.", status: :see_other
  end

  def read_notice
    workflow_actions.read_notice(id: params[:id], operation_id: params[:operation_id])
    redirect_to workflow_tasks_path, notice: "Aviso marcado como leído.", status: :see_other
  end
end
