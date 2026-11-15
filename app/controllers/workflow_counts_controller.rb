class WorkflowCountsController < WorkflowManagementController
  def show
    render json: { counts: helpers.workflow_counts, revision: [ Current.company.workflow_events.maximum(:id), Current.company.internal_notices.where(user: Current.user).unread.count, Current.company.opportunities_changed_at, Current.company.opportunities_evaluated_at ] }
  end
end
