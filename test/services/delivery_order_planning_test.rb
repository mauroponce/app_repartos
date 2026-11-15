require "test_helper"

class DeliveryOrderPlanningTest < ActiveSupport::TestCase
  def manual_order(time: "09:00", customer: customers(:one), **attributes)
    order = companies(:one).delivery_orders.new({ customer: customer, scheduled_date: "2026-11-17", preferred_time: time }.merge(attributes))
    order.delivery_order_items.build(description: "Manual", quantity: 2, unit: "box")
    order.save!
    order
  end

  def plan(orders, name: "Zona Sur")
    run = companies(:one).delivery_runs.new(name: name, scheduled_date: "2026-11-17", driver: users(:driver), status: :assigned)
    DeliveryRunPlanner.call(company: companies(:one), delivery_run: run, order_ids: orders.map(&:id))
  end

  test "recurrence generates pending orders without routes and retries preserve exceptions" do
    orders = nil
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      orders = DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17")
    end
    assert_equal 1, orders.size
    order = orders.first
    assert_equal 20, order.delivery_order_items.first.quantity
    DeliveryOrderEditor.call(order: order, attributes: { delivery_order_items_attributes: [ { id: order.delivery_order_items.first.id, quantity: 30 } ] })
    assert_no_difference [ "DeliveryOrder.count", "DeliveryOrderItem.count" ] do
      DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17")
    end
    assert_equal 30, order.reload.delivery_order_items.first.quantity
    assert_equal 20, delivery_schedule_items(:bread).reload.quantity
    assert_equal 20, DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-24").first.delivery_order_items.first.quantity
  end

  test "compatible orders group while incompatible times create separate stops" do
    orders = [ manual_order, manual_order, manual_order(time: "15:00"), manual_order(time: nil) ]
    run = plan(orders)
    assert_equal 3, run.visits.count
    assert_equal orders[0].reload.visit, orders[1].reload.visit
    assert_not_equal orders[0].visit, orders[2].reload.visit
    assert_equal 4, run.delivery_orders.count
    assert_equal 4, DeliveryItem.where(visit_id: run.visits.select(:id)).count
    assert_no_difference [ "Visit.count", "DeliveryItem.count" ] do
      DeliveryRunPlanner.call(company: companies(:one), delivery_run: run, order_ids: orders.map(&:id))
    end
  end

  test "ten deliveries split into independent routes and cannot be assigned twice" do
    orders = 10.times.map { manual_order }
    north = plan(orders.first(4), name: "Norte")
    south = plan(orders.last(6))
    other_driver = companies(:one).users.create!(name: "Otro repartidor", email_address: "planning-driver@example.test", password: "Password-test-2026", role: :driver)
    south.update!(driver: other_driver)
    assert_not_equal north.driver_id, south.driver_id
    assert_equal 4, north.delivery_orders.count
    assert_equal 6, south.delivery_orders.count
    assert_raises ArgumentError do
      DeliveryRunPlanner.call(company: companies(:one), delivery_run: south, order_ids: [ orders.first.id ])
    end
    assert_equal north.id, orders.first.reload.visit.delivery_run_id
  end

  test "reordering and driver reassignment preserve identities and quantities" do
    run = plan([ manual_order, manual_order(time: "15:00") ])
    ids = run.visits.pluck(:id)
    DeliveryRunReorderer.call(company: companies(:one), delivery_run: run, visit_ids: ids.reverse)
    assert_equal ids.reverse, run.visits.reload.pluck(:id)
    run.update!(driver: nil, status: :draft)
    run.update!(driver: users(:driver), status: :assigned)
    assert_equal ids.sort, run.visits.pluck(:id).sort
    assert_raises(ArgumentError) { DeliveryRunReorderer.call(company: companies(:one), delivery_run: run, visit_ids: [ ids.first, ids.first ]) }
  end

  test "assigned editing synchronizes planning preserves trace ids and completed partial execution" do
    order = DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17").first
    run = plan([ order ])
    item = order.reload.delivery_order_items.first
    execution = item.delivery_item
    DeliveryOrderEditor.call(order: order, attributes: { delivery_order_items_attributes: [ { id: item.id, quantity: 30 } ] })
    assert_equal 30, execution.reload.planned_quantity
    assert_equal execution.id, item.reload.delivery_item.id
    visit = order.reload.visit
    visit.update!(delivery_items_attributes: [ { id: execution.id, delivered_quantity: 18 } ], status: :completed, confirmed_by: users(:one))
    assert order.reload.needs_attention?
    assert_equal 30, item.reload.quantity
    assert_equal 18, execution.reload.delivered_quantity
    assert_equal(-12, execution.difference)
    assert_raises(ArgumentError) { DeliveryOrderEditor.call(order: order, attributes: { notes: "Overwrite" }) }
    assert_not visit.update(status: :pending)
    assert_not execution.update(planned_quantity: 10)
    assert_not visit.delivery_items.build(description: "Extra", unit: "box", planned_quantity: 1).save
    assert_raises(ArgumentError) { DeliveryRunReorderer.call(company: companies(:one), delivery_run: run, visit_ids: [ visit.id ]) }
  end

  test "assigned edits add and remove products without recreating surviving execution ids" do
    order = manual_order
    run = plan([ order ])
    original = order.delivery_order_items.first
    execution_id = original.delivery_item.id
    DeliveryOrderEditor.call(order: order, attributes: { delivery_order_items_attributes: [ { description: "Extra", unit: "kg", quantity: "1.125" } ] })
    assert_equal 2, order.reload.delivery_order_items.count
    assert_equal execution_id, original.reload.delivery_item.id
    extra = order.delivery_order_items.last
    DeliveryOrderEditor.call(order: order, attributes: { delivery_order_items_attributes: [ { id: original.id, _destroy: "1" }, { id: extra.id, quantity: "2.125" } ] })
    assert_equal [ extra.id ], order.reload.delivery_order_items.pluck(:id)
    assert_equal [ BigDecimal("2.125") ], run.visits.first.delivery_items.pluck(:planned_quantity)
    assert_raises ActiveRecord::RecordInvalid do
      DeliveryOrderEditor.call(order: order, attributes: { delivery_order_items_attributes: [ { id: extra.id, _destroy: "1" } ] })
    end
    assert_equal 1, order.reload.delivery_order_items.count
    assert_equal 1, run.visits.first.delivery_items.count
  end

  test "different addresses and incompatible windows remain separate" do
    first = manual_order(time: nil, window_start: "08:00", window_end: "12:00")
    same = manual_order(time: nil, window_start: "08:00", window_end: "12:00")
    different = manual_order(time: nil, window_start: "14:00", window_end: "16:00")
    moved = manual_order(time: nil, window_start: "08:00", window_end: "12:00", customer_address: "Otra dirección")
    run = plan([ first, same, different, moved ])
    assert_equal 3, run.visits.count
    assert_equal first.reload.visit_id, same.reload.visit_id
    assert_not_equal first.visit_id, different.reload.visit_id
    assert_not_equal first.visit_id, moved.reload.visit_id
  end

  test "execution blocks destructive changes and duplicate trace creation" do
    order = manual_order
    run = plan([ order ])
    visit = order.reload.visit
    item = visit.delivery_items.first
    item.update!(delivered_quantity: 1)
    assert_raises(ArgumentError) { DeliveryOrderEditor.call(order: order, cancel: true) }
    assert_raises(ArgumentError) { DeliveryRunPlanner.remove(company: companies(:one), delivery_run: run, order_id: order.id) }
    assert_not order.delivery_order_items.first.update(quantity: 100)
    assert_raises ActiveRecord::RecordNotUnique do
      DeliveryItem.transaction(requires_new: true) do
        DeliveryItem.insert_all!([ item.attributes.except("id") ])
      end
    end
    assert_not run.update(scheduled_date: "2026-11-18")
    assert_equal 1, item.reload.delivered_quantity
  end

  test "removal and cancellation preserve other grouped orders and manual stops" do
    orders = [ manual_order, manual_order ]
    run = plan(orders)
    manual = run.visits.create!(customer: customers(:one), position: 2)
    manual.delivery_items.create!(description: "Adicional", unit: "unit", planned_quantity: 1)
    DeliveryRunPlanner.remove(company: companies(:one), delivery_run: run, order_id: orders.first.id)
    assert_nil orders.first.reload.visit
    assert_equal 2, run.visits.count
    DeliveryOrderEditor.call(order: orders.last, cancel: true)
    assert orders.last.reload.cancelled?
    assert_equal [ manual.id ], run.visits.reload.pluck(:id)
  end
end
