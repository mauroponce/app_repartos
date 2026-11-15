require "test_helper"
require_relative "../test_helpers/workflow_test_helper"

class InternalWorkflowsTest < ActiveSupport::TestCase
  include WorkflowTestHelper
  setup do
    @company, @driver, @manager = companies(:one), users(:driver), users(:one)
    @order = workflow_order
    @run = workflow_plan([ @order ])
    @visit = @order.reload.visit
    @actions = WorkflowActions.new(@manager)
  end

  test "manual incident retries do not mutate execution or duplicate reports" do
    id = SecureRandom.uuid
    data = { visit_id: @visit.id, kind: "closed", description: "Cerrado", occurred_at: Time.current.iso8601 }
    original = @visit.attributes
    assert_difference "Incident.count", 1 do
      first = IncidentRecorder.report(user: @driver, operation_id: id, attributes: data)
      assert_equal first, IncidentRecorder.report(user: @driver, operation_id: id, attributes: data)
    end
    incident = @company.incidents.sole
    assert_equal @driver, incident.reporter
    assert_equal original, @visit.reload.attributes
    assert_raises(WorkflowCommands::Conflict) { IncidentRecorder.report(user: @driver, operation_id: id, attributes: data.merge(description: "Otro")) }
    assert_raises(ActiveRecord::RecordNotFound) { IncidentRecorder.report(user: users(:other_driver), operation_id: SecureRandom.uuid, attributes: data) }
    assert_not incident.update(description: "Reescritura del relato")
  end

  test "automatic failed execution links a matching manual report without duplicate incident" do
    workflow_report(@visit)
    assert_no_difference "Incident.count" do
      workflow_finish(@visit, status: "closed")
      IncidentRecorder.from_visit(@visit.reload)
    end
    assert_equal 1, @company.incidents.sole.workflow_events.where(action: "execution_recorded").count
    assert @order.reload.needs_attention?
  end

  test "partial execution creates an incident and recovery preserves all terminal history" do
    workflow_finish(@visit, quantities: [ 4 ])
    incident = @company.incidents.sole
    assert_equal "shortage", incident.kind
    snapshots = [ @visit.reload.attributes, @order.reload.attributes, @visit.delivery_items.first.attributes ]
    id = SecureRandom.uuid
    values = { version: incident.lock_version, action: "reprogram", message: "Llevar los seis paquetes pendientes mañana", date: @company.local_date + 1 }
    assert_difference [ "WorkflowTask.count", "DeliveryOrder.count" ], 1 do
      result = @actions.incident_action(id: incident.id, operation_id: id, attributes: values)
      assert_equal result, @actions.incident_action(id: incident.id, operation_id: id, attributes: values)
    end
    recovery = @order.reload.rescheduled_order
    assert_equal 6, recovery.delivery_order_items.sole.quantity
    assert_equal snapshots, [ @visit.reload.attributes, @order.reload.attributes, @visit.delivery_items.first.reload.attributes ]
    assert_equal "follow_up", incident.reload.status
    assert_equal @manager, incident.workflow_events.order(:id).last.user
    assert_equal "reprogram", incident.workflow_events.order(:id).last.action
    assert DriverInbox.new(@driver).notices.any? { |notice| notice.body.include?("seis paquetes") }
  end

  test "driver reads instruction starts and completes assigned task with separate acknowledgements" do
    incident = @company.incidents.find(workflow_report(@visit).fetch("incident_id"))
    result = @actions.incident_action(id: incident.id, operation_id: SecureRandom.uuid, attributes: { version: 0, action: "retry", message: "Volver después de las 14" })
    task = @company.workflow_tasks.find(result.fetch("task_id"))
    inbox = DriverInbox.new(@driver)
    notice = inbox.notices.find { |item| item.workflow_task_id == task.id }
    assert_nil notice.read_at
    driver_actions = WorkflowActions.new(@driver)
    driver_actions.read_notice(id: notice.id, operation_id: SecureRandom.uuid)
    assert notice.reload.read_at
    assert_nil notice.acknowledged_at
    driver_actions.update_task(id: task.id, operation_id: SecureRandom.uuid, attributes: { version: 0, action: "start" })
    assert_equal "in_progress", task.reload.status
    assert_raises(WorkflowCommands::Conflict) { driver_actions.update_task(id: task.id, operation_id: SecureRandom.uuid, attributes: { version: 0, action: "complete", result: "Listo" }) }
    driver_actions.update_task(id: task.id, operation_id: SecureRandom.uuid, attributes: { version: task.lock_version, action: "complete", result: "Se reintentó y el cliente confirmó recepción" })
    assert_equal "completed", task.reload.status
    assert notice.reload.acknowledged_at
    assert @visit.reload.pending?
    assert_nil @visit.delivery_items.first.delivered_quantity
    assert_equal @driver.id, task.workflow_events.order(:id).last.user_id
  end

  test "commercial task access and tenant links are enforced by models services and database" do
    result = @actions.create_task(operation_id: SecureRandom.uuid, attributes: { title: "Contactar cliente", category: "commercial", assignee_id: @manager.id, customer_id: @order.customer_id })
    task = @company.workflow_tasks.find(result.fetch("task_id"))
    assert_empty WorkflowTask.visible_to_driver(@driver).where(id: task.id)
    assert_raises(ActiveRecord::RecordNotFound) { WorkflowActions.new(@driver).update_task(id: task.id, operation_id: SecureRandom.uuid, attributes: { action: "complete", version: 0, result: "No autorizado" }) }
    assert_raises(ActiveRecord::RecordInvalid) { @actions.create_task(operation_id: SecureRandom.uuid, attributes: { title: "Interna", category: "commercial", assignee_id: @driver.id }) }
    assert_raises(ActiveRecord::RecordNotFound) { @actions.create_task(operation_id: SecureRandom.uuid, attributes: { title: "Ajena", category: "commercial", customer_id: customers(:other_company).id }) }
    assert_raises(ActiveRecord::InvalidForeignKey) { WorkflowTask.transaction(requires_new: true) { task.update_columns(assignee_id: users(:two).id) } }
    assert_not task.workflow_events.first.update(message: "Reescribir auditoría")
    @actions.update_task(id: task.id, operation_id: SecureRandom.uuid, attributes: { action: "complete", version: 0, result: "Contacto documentado" })
    assert_not task.reload.update(result: "Cambiar resultado cerrado")
  end

  test "driver receives incident decision even when its follow up belongs to administration" do
    incident = @company.incidents.find(workflow_report(@visit).fetch("incident_id"))
    result = @actions.incident_action(id: incident.id, operation_id: SecureRandom.uuid, attributes: {
      version: 0, action: "follow_up", message: "Administración verificará la dirección; continuá con la ruta", assignee_id: @manager.id
    })
    task = @company.workflow_tasks.find(result.fetch("task_id"))
    inbox = DriverInbox.new(@driver)
    assert_not inbox.task_scope.exists?(task.id)
    notice = inbox.notices.find { |item| item.incident_id == incident.id }
    assert_equal "Administración verificará la dirección; continuá con la ruta", notice.body
    assert_nil notice.workflow_task_id
    WorkflowActions.new(@driver).read_notice(id: notice.id, operation_id: SecureRandom.uuid)
    assert notice.reload.read_at
    assert_not DriverInbox.new(users(:other_driver)).notice_scope.exists?(notice.id)
  end

  test "incidents resolve with a reason and original photo and decision ownership remain tenant scoped" do
    incident = @company.incidents.find(workflow_report(@visit).fetch("incident_id"))
    assert_raises(ArgumentError) { @actions.incident_action(id: incident.id, operation_id: SecureRandom.uuid, attributes: { version: 0, action: "resolve", message: "" }) }
    @actions.incident_action(id: incident.id, operation_id: SecureRandom.uuid, attributes: { version: 0, action: "resolve", message: "Se corrigió la dirección en el directorio" })
    assert_equal "resolved", incident.reload.status
    assert incident.resolved_at
    assert @visit.reload.pending?
    assert_raises(WorkflowCommands::Conflict) { @actions.incident_action(id: incident.id, operation_id: SecureRandom.uuid, attributes: { version: incident.lock_version, action: "decision", message: "Cambio" }) }
    assert_raises(ActiveRecord::RecordNotFound) { WorkflowActions.new(users(:two)).incident_action(id: incident.id, operation_id: SecureRandom.uuid, attributes: { version: 0, action: "resolve", message: "No" }) }
  end
end
