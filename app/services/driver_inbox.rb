class DriverInbox
  attr_reader :user
  def initialize(user)
    @user = user
  end

  def task_scope
    WorkflowTask.visible_to_driver(user)
  end

  def notice_scope
    base = InternalNotice.where(company_id: user.company_id, user_id: user.id)
    base.where(workflow_task_id: task_scope.select(:id)).or(base.where(workflow_task_id: nil, incident_id: Incident.visible_to_driver(user).select(:id)))
  end

  def pending_count
    @pending_count ||= notice_scope.unread.count + task_scope.unfinished.where.not(id: notice_scope.unread.where.not(workflow_task_id: nil).select(:workflow_task_id)).count
  end

  def notices(page = 1)
    notice_scope.order(id: :desc).limit(20).offset((page.to_i.clamp(1, 10_000) - 1) * 20).to_a
  end

  def tasks(page = 1)
    @tasks ||= {}
    @tasks[page] ||= task_scope.unfinished.includes(:incident).order(Arel.sql("due_at ASC NULLS LAST"), :id).limit(30).offset((page.to_i.clamp(1, 10_000) - 1) * 30).to_a
  end

  def incidents(page = 1)
    @incidents ||= {}
    @incidents[page] ||= Incident.visible_to_driver(user).order(id: :desc).limit(20).offset((page.to_i.clamp(1, 10_000) - 1) * 20).to_a
  end
end
