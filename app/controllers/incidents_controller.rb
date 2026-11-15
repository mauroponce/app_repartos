class IncidentsController < WorkflowManagementController
  before_action :workflow_options

  def index
    relation = Current.company.incidents.includes(:driver, :customer, :assigned_to, :delivery_run)
    %w[kind priority status driver_id delivery_run_id customer_id assigned_to_id].each do |field|
      relation = relation.where(field => params[field]) if params[field].present? && params[field] != "overdue"
    end
    relation = relation.unresolved.where("due_at < ?", Time.current) if params[:status] == "overdue"
    relation = relation.where("COALESCE(incidents.occurred_at, incidents.created_at) >= ?", Date.iso8601(params[:start_on]).in_time_zone.beginning_of_day) if params[:start_on].present?
    relation = relation.where("COALESCE(incidents.occurred_at, incidents.created_at) < ?", (Date.iso8601(params[:end_on]) + 1).in_time_zone.beginning_of_day) if params[:end_on].present?
    @incidents = paginate(relation.order(created_at: :desc, id: :desc))
    @counts = Current.company.incidents.group(:status).count
    @overdue = Current.company.incidents.unresolved.where("due_at < ?", Time.current).count
  end

  def show
    @incident = Current.company.incidents.includes(:reporter, :driver, :assigned_to, :customer, :delivery_run, incident_photos: { file_attachment: :blob }).find(params[:id])
    @events = @incident.workflow_events.includes(:user).order(:id)
    @tasks = @incident.workflow_tasks.includes(:assignee, :customer).order(:id)
  end

  def act
    result = workflow_actions.incident_action(id: params[:id], operation_id: params[:operation_id], attributes: params.expect(decision: [ :action, :message, :version, :responsible_id, :assignee_id, :date, :due_at ]).to_h)
    redirect_to incident_path(result.fetch("incident_id")), notice: "Decisión registrada y aviso interno generado.", status: :see_other
  end
end
