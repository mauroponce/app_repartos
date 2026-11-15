class WorkflowManagementController < ManagementController
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  rescue_from WorkflowCommands::Forbidden, with: -> { head :forbidden }
  rescue_from ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError, WorkflowCommands::Conflict, with: :invalid_workflow

  private

  def workflow_actions
    WorkflowActions.new(Current.user)
  end

  def workflow_options
    @staff = Current.company.users.active.alphabetical.to_a
    @customers = Current.company.customers.alphabetical.limit(30).to_a
    if params[:customer_id].present?
      selected = Current.company.customers.find_by(id: params[:customer_id])
      @customers << selected if selected && !@customers.any? { |customer| customer.id == selected.id }
    end
    @runs = Current.company.delivery_runs.order(scheduled_date: :desc, id: :desc).limit(30).to_a
    selected_run_id = params[:run_id].presence || params[:delivery_run_id].presence
    if selected_run_id
      selected = Current.company.delivery_runs.find_by(id: selected_run_id)
      @runs << selected if selected && !@runs.any? { |run| run.id == selected.id }
    end
  end

  def invalid_workflow(error)
    redirect_back fallback_location: workflow_tasks_path, alert: error.message, status: :see_other
  end
end
