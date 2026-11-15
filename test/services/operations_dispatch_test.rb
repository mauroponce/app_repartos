require "test_helper"

class OperationsDispatchTest < ActiveSupport::TestCase
  setup do
    @company = companies(:one)
    @driver = users(:driver)
    @manager = users(:one)
    @date = @company.local_date
  end

  def order(time: "10:00")
    @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @date, preferred_time: time,
      delivery_order_items_attributes: [ { description: "Pan", unit: "pack", quantity: 10 } ])
  end

  def plan_run(orders, driver: @driver)
    row = @company.delivery_runs.new(name: "Operaciones", scheduled_date: @date, driver: driver, status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: row, order_ids: orders.map(&:id))
  end

  def dispatch(order, target: nil, date: @date, **attributes)
    OperationsDispatch.call(user: @manager, order_id: order.id, target_run_id: target&.id, date: date,
      revision: OperationsDispatch.revision(order.reload), reason: "Vehículo con avería", **attributes)
  end

  test "moving an order between started routes preserves completed history and grouped merchandise" do
    completed, moved, grouped = order(time: "08:00"), order, order
    source = plan_run([ completed, moved, grouped ])
    target_order = order(time: "12:00")
    target = plan_run([ target_order ])
    DriverVisitRecorder.call(user: @driver, visit_id: completed.reload.visit_id, attributes: {
      status: "completed", items: [ { id: completed.visit.delivery_items.first.id, delivered_quantity: "10" } ] })
    target.update!(status: :in_progress)
    completed_item = completed.visit.delivery_items.first
    original = moved.reload.visit
    grouped_item_id = grouped.reload.delivery_order_items.first.delivery_item.id
    proof = DriverWorkSnapshot.issue(user: @driver, visit: original)
    dispatch(moved, target: target)
    assert_equal target.id, moved.reload.visit.delivery_run_id
    assert_equal original.id, grouped.reload.visit_id
    assert_equal grouped_item_id, grouped.delivery_order_items.first.reload.delivery_item.id
    assert_equal 10, completed_item.reload.delivered_quantity
    assert_equal "completed", completed.visit.reload.status
    assert_equal "in_progress", source.reload.status
    assert_equal moved.visit_id, moved.delivery_order_items.first.reload.delivery_item.visit_id
    audit = @company.delivery_dispatch_changes.last
    assert_equal @manager.id, audit.user_id
    assert_equal source.id, audit.before_data["run_id"]
    assert_equal target.id, audit.after_data["run_id"]
    # Another order remained at the original stop. Its stale download now
    # conflicts instead of delivering the moved order a second time.
    result = DriverOperationSync.call(user: @driver, attributes: { operation_id: SecureRandom.uuid, visit_id: original.id,
      status: "closed", notes: "Sin conexión", recorded_at: Time.current.iso8601, proof: proof })
    assert_equal "conflict", result.status
    assert grouped.reload.pending?
    assert_not audit.update(reason: "Ocultar cambio")
  end

  test "reprogramming last pending order completes started source and preserves the order" do
    done, pending = order(time: "08:00"), order
    source = plan_run([ done, pending ])
    DriverVisitRecorder.call(user: @driver, visit_id: done.reload.visit_id, attributes: {
      status: "completed", items: [ { id: done.visit.delivery_items.first.id, delivered_quantity: "10" } ] })
    old_id = pending.reload.visit_id
    dispatch(pending, date: @date + 1)
    assert_equal @date + 1, pending.reload.scheduled_date
    assert_nil pending.visit_id
    assert pending.pending?
    assert_equal "completed", source.reload.status
    assert_not Visit.exists?(old_id)
    assert_equal 10, pending.delivery_order_items.first.quantity
  end

  test "stale requests foreign destinations invalid reasons and recorded quantities roll back" do
    pending = order
    source = plan_run([ pending ])
    target = plan_run([])
    revision = OperationsDispatch.revision(pending.reload)
    pending.update!(notes: "Cambió")
    assert_raises(ArgumentError) { dispatch(pending, target: target, revision: revision) }
    foreign = companies(:two).delivery_runs.create!(name: "Privada", scheduled_date: @date, status: :assigned, driver: users(:other_driver))
    assert_raises(ActiveRecord::RecordNotFound) { dispatch(pending, target: foreign) }
    assert_raises(ActiveRecord::RecordInvalid) { dispatch(pending, target: target, reason: "") }
    assert_equal source.id, pending.reload.visit.delivery_run_id
    pending.visit.delivery_items.first.update!(delivered_quantity: 1)
    assert_raises(ArgumentError) { dispatch(pending, target: target) }
    assert_empty @company.delivery_dispatch_changes
  end

  test "completed orders cannot move and normal planning guards still apply" do
    pending = order
    source = plan_run([ pending ])
    target = plan_run([])
    target.update!(status: :in_progress)
    other = order(time: "14:00")
    assert_raises(ArgumentError) { DeliveryRunPlanner.call(company: @company, delivery_run: target, order_ids: [ other.id ]) }
    dispatch(other, target: target)
    DriverVisitRecorder.call(user: @driver, visit_id: pending.reload.visit_id, attributes: {
      status: "closed", notes: "Cerrado" })
    assert_raises(ArgumentError) { dispatch(pending, target: target) }
    assert_equal source.id, pending.reload.visit.delivery_run_id
  end
end
