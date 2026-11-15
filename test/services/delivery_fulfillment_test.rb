require "test_helper"

class DeliveryFulfillmentTest < ActiveSupport::TestCase
  setup do
    @company = companies(:one)
    @driver = users(:driver)
  end

  test "all unsuccessful outcomes preserve the attempt and expose an unfulfilled order" do
    %w[not_attended closed rescheduled].each do |status|
      order, run, visit = planned_order
      original = order.delivery_order_items.first.attributes
      recorded_at = Time.current.change(usec: 0)
      travel_to recorded_at do
        record(visit, status: status, notes: "No se pudo entregar")
      end
      assert_equal status, visit.reload.status
      assert_nil visit.completed_at
      assert_equal @driver, visit.confirmed_by
      assert_equal recorded_at, visit.confirmed_at
      assert order.reload.needs_attention?
      assert_equal "none", order.fulfillment_result
      assert_includes @company.delivery_orders.requiring_intervention, order
      assert_not_includes @company.delivery_orders.unplanned, order
      assert_equal original, order.delivery_order_items.first.reload.attributes
      assert_equal 20, visit.delivery_items.first.planned_quantity
      assert_equal 0, visit.delivery_items.first.delivered_quantity
      assert run.reload.completed?
      assert_not visit.update(status: :pending)
      assert_not visit.reload.update(confirmed_by: users(:one))
      assert_not visit.reload.update(confirmed_at: 1.hour.ago)
      assert_not visit.reload.update(notes: "Otro resultado")
      assert_not visit.reload.delivery_items.first.update(delivered_quantity: 2)
    end
  end

  test "completed visits distinguish full partial and zero fulfillment" do
    [ [ 20, "completed", "full", 0 ], [ 18, "needs_attention", "partial", 2 ], [ 0, "needs_attention", "none", 20 ] ].each do |delivered, status, result, remaining|
      order, _, visit = planned_order
      record(visit, quantities: [ delivered ])
      assert visit.reload.completed?
      assert_equal status, order.reload.status
      assert_equal result, order.fulfillment_result
      assert_equal remaining, order.delivery_order_items.first.remaining_quantity
      assert_equal 20, order.delivery_order_items.first.quantity
      assert_equal delivered, visit.delivery_items.first.delivered_quantity
    end
  end

  test "each product must be covered and surplus cannot compensate another product" do
    order, _, visit = planned_order(items: [ [ "Pan", "pack", 20 ], [ "Aceite", "l", "2.500" ], [ "Harina", "bag", 3 ] ])
    record(visit, quantities: [ 22, "2.125", 0 ])
    assert order.reload.needs_attention?
    assert_equal "partial", order.fulfillment_result
    assert_equal [ 0, BigDecimal("0.375"), 3 ], order.delivery_order_items.map(&:remaining_quantity)
    replacement = reschedule(order)
    assert_equal [ [ "Aceite", "l", BigDecimal("0.375") ], [ "Harina", "bag", 3 ] ], replacement.delivery_order_items.pluck(:description, :unit, :quantity)
    assert_equal [ 20, BigDecimal("2.500"), 3 ], order.delivery_order_items.reload.map(&:quantity)
  end

  test "orders grouped in one visit have independent fulfillment results" do
    first, run, visit = planned_order
    second = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: run.scheduled_date,
      delivery_order_items_attributes: [ { description: "Extra", unit: "bag", quantity: 4 } ])
    DeliveryRunPlanner.call(company: @company, delivery_run: run, order_ids: [ second.id ])
    assert_equal visit.id, second.reload.visit_id
    record(visit, quantities: [ 20, 0 ])
    assert first.reload.completed?
    assert second.reload.needs_attention?
    assert_equal "none", second.fulfillment_result
  end

  test "rescheduling copies only shortages with historical snapshots and supports repeated attempts" do
    order, run, visit = planned_order
    record(visit, quantities: [ 18 ])
    visit_snapshot = visit.reload.attributes
    item_snapshot = visit.delivery_items.first.attributes
    customers(:one).update!(name: "Otro nombre", address: "Otra dirección")
    replacement = reschedule(order)
    assert replacement.pending?
    assert_nil replacement.visit_id
    assert_nil replacement.delivery_schedule_id
    assert_equal order.id, replacement.rescheduled_from_id
    assert_equal order.customer_name, replacement.customer_name
    assert_equal order.customer_address, replacement.customer_address
    assert_equal [ BigDecimal("2") ], replacement.delivery_order_items.pluck(:quantity)
    assert_not_includes @company.delivery_orders.requiring_intervention, order
    assert_no_difference [ "DeliveryOrder.count", "DeliveryOrderItem.count", "Visit.count", "DeliveryItem.count" ] do
      assert_equal replacement.id, reschedule(order).id
    end
    assert_raises(ArgumentError) { reschedule(order, date: replacement.scheduled_date + 1) }
    assert_raises(ArgumentError) { DeliveryRunPlanner.call(company: @company, delivery_run: run, order_ids: [ order.id ]) }
    new_run = @company.delivery_runs.new(name: "Reintento", scheduled_date: replacement.scheduled_date)
    DeliveryRunPlanner.call(company: @company, delivery_run: new_run, order_ids: [ replacement.id ])
    new_visit = replacement.reload.visit
    new_visit.update!(status: :closed, confirmed_by: users(:one))
    next_attempt = reschedule(replacement, date: replacement.scheduled_date + 1)
    assert_equal replacement.id, next_attempt.rescheduled_from_id
    assert_equal visit_snapshot, visit.reload.attributes
    assert_equal item_snapshot, visit.delivery_items.first.reload.attributes
    assert_equal order.id, replacement.reload.rescheduled_from_id
    assert_equal "partial", order.reload.fulfillment_result
  end

  test "fully delivered pending cancelled and unknown historical orders cannot be rescheduled" do
    order, _, visit = planned_order
    assert_raises(ArgumentError) { reschedule(order) }
    record(visit, quantities: [ 20 ])
    assert_raises(ArgumentError) { reschedule(order) }
    order, _, visit = planned_order
    # Simulate data recorded before confirmation auditing existed.
    visit.update_columns(status: "completed", completed_at: 1.day.ago)
    order.update_columns(status: "needs_attention")
    assert_equal "unknown", order.reload.fulfillment_result
    assert_raises(ArgumentError) { reschedule(order) }
    assert_nil visit.reload.confirmed_by
    assert_nil visit.confirmed_at
    assert_nil visit.delivery_items.first.delivered_quantity
    assert_not visit.update(notes: "Invented history")
  end

  test "rescheduling validates dates tenancy immutable ancestry and database deduplication" do
    order, _, visit = planned_order
    record(visit, status: "closed", notes: "Cerrado")
    assert_raises(ArgumentError) { reschedule(order, date: "not-a-date") }
    assert_raises(ActiveRecord::RecordInvalid) { reschedule(order, date: order.scheduled_date) }
    assert_raises(ActiveRecord::RecordNotFound) do
      DeliveryOrderRescheduler.call(company: companies(:two), order_id: order.id, date: order.scheduled_date + 1)
    end
    replacement = reschedule(order)
    assert_not replacement.update(rescheduled_from: nil)
    assert_raises(ActiveRecord::RecordNotUnique) do
      DeliveryOrder.transaction(requires_new: true) { DeliveryOrder.insert_all!([ replacement.reload.attributes.except("id") ]) }
    end
    assert_raises(ActiveRecord::InvalidForeignKey) do
      DeliveryOrder.transaction(requires_new: true) { replacement.update_columns(company_id: companies(:two).id, customer_id: customers(:other_company).id) }
    end
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Visit.transaction(requires_new: true) { visit.update_columns(confirmed_by_id: users(:other_driver).id) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      Visit.transaction(requires_new: true) { visit.update_columns(confirmed_at: nil) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      DeliveryOrder.transaction(requires_new: true) { replacement.reload.update_columns(rescheduled_from_id: replacement.id) }
    end
    assert_not replacement.reload.update(customer: customers(:inactive))
    assert_raises(ActiveRecord::InvalidForeignKey) do
      DeliveryOrder.transaction(requires_new: true) { replacement.reload.update_columns(customer_id: customers(:inactive).id) }
    end
  end

  test "confirmation requires an author from the tenant and cannot report failed delivery with positive quantities" do
    _, _, visit = planned_order
    assert_not visit.update(status: :completed, delivery_items_attributes: [ { id: visit.delivery_items.first.id, delivered_quantity: 20 } ])
    visit.reload
    assert_not visit.update(status: :closed, confirmed_by: users(:other_driver))
    visit.reload
    assert_not visit.update(status: :closed, confirmed_by: users(:one), delivery_items_attributes: [ { id: visit.delivery_items.first.id, delivered_quantity: 2 } ])
    assert visit.reload.pending?
    assert_nil visit.confirmed_at
    assert_nil visit.delivery_items.first.delivered_quantity
  end

  private

  def planned_order(items: [ [ "Pan", "pack", 20 ] ])
    order = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @company.local_date,
      delivery_order_items_attributes: items.map.with_index { |(description, unit, quantity), index| { description: description, unit: unit, quantity: quantity, position: index } })
    run = @company.delivery_runs.new(name: "Cumplimiento", scheduled_date: order.scheduled_date, driver: @driver, status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: run, order_ids: [ order.id ])
    [ order.reload, run, order.visit ]
  end

  def record(visit, status: "completed", notes: nil, quantities: [])
    rows = visit.delivery_items.order(:id).zip(quantities).map { |item, quantity| { id: item.id, delivered_quantity: quantity } }
    DriverVisitRecorder.call(user: @driver, visit_id: visit.id, attributes: { status: status, notes: notes, items: rows })
  end

  def reschedule(order, date: order.scheduled_date + 1)
    DeliveryOrderRescheduler.call(company: @company, order_id: order.id, date: date)
  end
end
