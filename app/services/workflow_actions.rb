class WorkflowActions
  INCIDENT_ACTIONS = { "request_info" => "Solicitar más información", "retry" => "Reintentar entrega", "reprogram" => "Reprogramar entrega", "return" => "Devolver al depósito", "follow_up" => "Seguimiento asignado", "decision" => "Decisión registrada", "resolve" => "Resolver", "dismiss" => "Descartar", "assign" => "Asignar responsable" }.freeze

  def initialize(user)
    @user, @company = user, user.company
  end

  def create_task(operation_id:, attributes:)
    command(operation_id, "create_task", attributes) do
      manager!
      task = build_task(attributes.symbolize_keys, "manual:#{operation_id}")
      { task_id: task.id }
    end
  end

  def update_task(id:, operation_id:, attributes:)
    command(operation_id, "update_task", attributes.merge(id: id)) do
      scope = @user.driver? ? WorkflowTask.visible_to_driver(@user) : @company.workflow_tasks
      task = scope.find(id)
      values = attributes.symbolize_keys
      check_version!(task, values[:version])
      raise WorkflowCommands::Conflict, "La tarea ya está cerrada" if task.terminal?
      action = values[:action].to_s
      if @user.driver?
        raise WorkflowCommands::Forbidden, "Acción no habilitada" unless action.in?(%w[start complete])
      else
        manager!
        if values.key?(:assignee_id)
          task.assignee = values[:assignee_id].present? ? @company.users.active.find(values[:assignee_id]) : nil
        end
        task.assign_attributes(values.slice(:title, :description, :priority, :due_at))
      end
      case action
      when "start" then task.status = "in_progress"
      when "complete", "cancel"
        raise WorkflowCommands::Forbidden, "No podés cancelar esta tarea" if action == "cancel" && @user.driver?
        task.assign_attributes(status: action == "complete" ? "completed" : "cancelled", closed_at: Time.current, result: values[:result])
      when "update"
        manager!
      else raise ArgumentError, "Elegí una acción válida"
      end
      changes = task.changes.deep_dup
      task.save!
      event(task, "task_#{action}", values[:result].presence || "Tarea actualizada", changes)
      notify_task(task, "task:#{task.id}:#{task.lock_version}") if changes.key?("assignee_id")
      if task.terminal?
        @company.internal_notices.where(user_id: @user.id, workflow_task: task, acknowledged_at: nil).find_each do |notice|
          notice.update!(read_at: notice.read_at || Time.current, acknowledged_at: Time.current)
        end
        notice(task.creator, "Resultado de tarea: #{task.title}".first(255), task.result, "task:#{task.id}:closed", task: task) if task.creator_id != @user.id
      end
      { task_id: task.id, task_status: task.status, closed_at: task.closed_at }
    end
  end

  def incident_action(id:, operation_id:, attributes:)
    command(operation_id, "incident_action", attributes.merge(id: id)) do
      manager!
      incident = @company.incidents.find(id)
      values = attributes.symbolize_keys
      check_version!(incident, values[:version])
      raise WorkflowCommands::Conflict, "La incidencia ya está cerrada" if incident.terminal?
      action, message = values[:action].to_s, values[:message].to_s.strip
      raise ArgumentError, "Elegí una acción y registrá el motivo o instrucción" unless INCIDENT_ACTIONS.key?(action) && message.present? && message.length <= 4000
      changes = {}
      if values[:responsible_id].present?
        incident.assigned_to = @company.users.active.where(role: %w[administrator supervisor]).find(values[:responsible_id])
      end
      recovery_ids = reprogram(incident, values[:date], message) if action == "reprogram"
      task = nil
      if action.in?(%w[request_info retry reprogram return follow_up])
        assignee_id = values[:assignee_id].presence || incident.driver_id || incident.reporter_id
        task = build_task({ title: "#{INCIDENT_ACTIONS.fetch(action)} · Incidencia ##{incident.id}", description: message,
          category: "operational", priority: incident.priority, assignee_id: assignee_id, due_at: values[:due_at], incident_id: incident.id }, "incident:#{incident.id}:#{operation_id}")
        incident.status = "follow_up"
      elsif action.in?(%w[resolve dismiss])
        incident.assign_attributes(status: action == "resolve" ? "resolved" : "dismissed", resolved_at: Time.current, resolution: message)
      else
        incident.status = "open"
      end
      incident.due_at = values[:due_at] if values[:due_at].present?
      changes.merge!(incident.changes)
      incident.save!
      changes[:recovery_order_ids] = recovery_ids if recovery_ids
      changes[:task_id] = task.id if task
      event(incident, action, message, changes)
      [ incident.reporter, incident.driver ].compact.uniq(&:id).each do |recipient|
        next if task && recipient.id == (task.assignee_id || task.delivery_run&.driver_id)
        notice(recipient, INCIDENT_ACTIONS.fetch(action), message, "incident:#{incident.id}:#{operation_id}", incident: incident)
      end
      { incident_id: incident.id, task_id: task&.id, recovery_order_ids: recovery_ids }
    end
  end

  def incident_response(id:, operation_id:, attributes:)
    command(operation_id, "incident_response", attributes.merge(id: id)) do
      incident = Incident.visible_to_driver(@user).find(id)
      raise WorkflowCommands::Forbidden unless @user.driver?
      raise WorkflowCommands::Conflict, "La incidencia ya está cerrada" if incident.terminal?
      message = attributes[:message].to_s.strip
      raise ArgumentError, "Describí la información solicitada (hasta 4.000 caracteres)" if message.blank? || message.length > 4000
      incident.update!(status: "needs_decision")
      event(incident, "information", message)
      { incident_id: incident.id }
    end
  end

  def read_notice(id:, operation_id:)
    command(operation_id, "read_notice", { id: id }) do
      scope = @user.driver? ? DriverInbox.new(@user).notice_scope : @company.internal_notices.where(user: @user)
      record = scope.find(id)
      record.update!(read_at: Time.current) unless record.read_at
      { notice_id: record.id, read_at: record.read_at }
    end
  end

  def opportunity_action(id:, operation_id:, attributes:)
    command(operation_id, "opportunity_action", attributes.merge(id: id)) do
      manager!
      record = @company.commercial_opportunities.find(id)
      values = attributes.symbolize_keys
      check_version!(record, values[:version])
      if values[:action] == "task"
        task = record.workflow_tasks.unfinished.order(:id).first
        source_key = "opportunity:#{record.id}:#{record.generation}"
        source_key = "#{source_key}:followup:#{operation_id}" if record.workflow_tasks.exists?(source_key: source_key)
        task ||= build_task({ title: record.title, description: values[:message].presence || record.evidence.to_json.first(4000), category: "commercial", priority: "normal",
          assignee_id: values[:assignee_id], due_at: values[:due_at], commercial_opportunity_id: record.id }, source_key)
        event(record, "task_created", "Seguimiento comercial documentado", { task_id: task.id })
        { opportunity_id: record.id, task_id: task.id }
      else
        action = values[:action].to_s
        raise ArgumentError, "Elegí una acción válida" unless action.in?(%w[managed snoozed dismissed])
        raise ArgumentError, "Registrá el motivo o resultado" if values[:message].blank?
        until_time = Time.zone.parse(values[:snoozed_until].to_s) if action == "snoozed"
        raise ArgumentError, "Elegí una fecha futura para retomar" if action == "snoozed" && (!until_time || until_time <= Time.current)
        record.assign_attributes(status: action, resolution: values[:message], snoozed_until: until_time, state_changed_at: Time.current, acknowledged_fingerprint: record.fingerprint)
        changes = record.changes.deep_dup
        record.save!
        event(record, action, values[:message], changes)
        { opportunity_id: record.id }
      end
    end
  end

  def build_task(values, source_key, system: false)
    incident = @company.incidents.find(values[:incident_id]) if values[:incident_id].present?
    opportunity = @company.commercial_opportunities.find(values[:commercial_opportunity_id]) if values[:commercial_opportunity_id].present?
    order = @company.delivery_orders.find(values[:delivery_order_id]) if values[:delivery_order_id].present?
    order ||= opportunity&.delivery_order
    customer_id = values[:customer_id].presence || incident&.customer_id || order&.customer_id || opportunity&.customer_id
    customer = @company.customers.find(customer_id) if customer_id
    visit = values[:visit_id].present? ? @company.visits.find(values[:visit_id]) : (incident&.visit || order&.visit)
    customer ||= visit&.customer
    run_id = values[:delivery_run_id].presence || visit&.delivery_run_id || incident&.delivery_run_id
    run = @company.delivery_runs.find(run_id) if run_id
    assignee = @company.users.active.find(values[:assignee_id]) if values[:assignee_id].present?
    task = @company.workflow_tasks.create!(values.slice(:title, :description, :category, :priority, :due_at).merge(
      creator: system ? nil : @user, assignee: assignee, customer: customer, visit: visit, delivery_run: run, incident: incident,
      delivery_order: order, commercial_opportunity: opportunity, source_key: source_key))
    event(task, "created", "Tarea creada", task.attributes.slice("category", "assignee_id", "due_at"), system: system)
    notify_task(task, "task:#{task.id}:created")
    task
  end

  def event(record, action, message, changes = {}, system: false)
    @company.workflow_events.create!(record.class.model_name.singular => record, user: system ? nil : @user,
      action: action, message: message, changeset: changes)
  end

  private

  def command(id, type, values, &block)
    WorkflowCommands.call(user: @user, operation_id: id, payload: { type: type, attributes: values }, &block)
  end

  def manager!
    raise WorkflowCommands::Forbidden, "Requiere administración o supervisión" unless @user.manages_customers?
  end

  def check_version!(record, version)
    raise WorkflowCommands::Conflict, "El registro cambió. Actualizá la pantalla antes de decidir." unless version.to_s == record.lock_version.to_s
  end

  def notify_task(task, key)
    recipient = task.assignee || task.delivery_run&.driver
    notice(recipient, task.title, task.description.presence || "Revisá la tarea asignada", key, task: task, incident: task.incident)
  end

  def notice(recipient, title, body, key, task: nil, incident: nil)
    return unless recipient
    @company.internal_notices.find_or_create_by!(user: recipient, source_key: key) do |record|
      record.assign_attributes(sender: @user, title: title, body: body, workflow_task: task, incident: incident)
    end
  end

  def reprogram(incident, date, message)
    visit = incident.visit
    raise ArgumentError, "La visita original ya no existe; generá una tarea de seguimiento" unless visit
    rows = visit.delivery_orders.to_a
    raise ArgumentError, "No hay pedidos con faltantes conocidos; generá una tarea de seguimiento" if rows.empty?
    ids = rows.filter_map do |order|
      if order.reschedulable?
        DeliveryOrderRescheduler.call(company: @company, order_id: order.id, date: date).id
      elsif order.pending? && visit.plannable?
        OperationsDispatch.call(user: @user, order_id: order.id, target_run_id: nil, date: date, revision: OperationsDispatch.revision(order), reason: message).id
      end
    end
    raise ArgumentError, "No hay faltantes reprogramables o la visita tiene ejecución en curso" if ids.empty?
    ids
  end
end
