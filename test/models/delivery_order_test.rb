require "test_helper"

class DeliveryOrderTest < ActiveSupport::TestCase
  def build_order(**attributes)
    order = companies(:one).delivery_orders.new({ customer: customers(:one), scheduled_date: "2026-11-17" }.merge(attributes))
    order.delivery_order_items.build(description: "Manual", quantity: 2, unit: "box")
    order
  end

  test "an order is independent and requires at least one valid catalog or manual item" do
    order = build_order
    order.delivery_order_items.build(product: products(:bread), quantity: 20)
    order.save!
    assert_nil order.visit
    assert order.pending?
    assert_equal 2, order.delivery_order_items.count
    assert_equal "Pan lactal", order.delivery_order_items.last.description
    order.delivery_order_items.each(&:mark_for_destruction)
    assert_not order.valid?
    assert_not build_order(scheduled_date: nil).valid?
    [ 0, -1, "1.5", "1.1234", "NaN" ].each do |quantity|
      item = build_order.delivery_order_items.first
      item.quantity = quantity
      assert_not item.valid?
    end
    item = build_order.delivery_order_items.first
    item.unit = "kg"
    item.quantity = "1.125"
    assert item.valid?
  end

  test "snapshots survive customer and catalog edits" do
    order = build_order
    order.save!
    customers(:one).update!(name: "Nuevo", address: "Nueva calle")
    assert_equal "Almacén San Martín", order.reload.customer_name
    assert_equal "San Martín 123, Adrogué", order.customer_address
  end

  test "tenant date customer and timing invariants are validated" do
    assert_not build_order(customer: customers(:other_company)).valid?
    order = build_order
    order.delivery_order_items.first.product = products(:almonds)
    assert_not order.valid?
    order = build_order(preferred_time: "09:00", window_start: "08:00", window_end: "12:00")
    assert_not order.valid?
    order.preferred_time = nil
    assert order.valid?
    run = companies(:one).delivery_runs.create!(name: "Otra fecha", scheduled_date: "2026-11-18")
    order.visit = run.visits.create!(customer: customers(:one), position: 1)
    assert_not order.valid?
  end

  test "completed orders and their original quantities are immutable" do
    order = build_order
    order.save!
    order.update!(status: :completed)
    assert_not order.update(notes: "Overwrite")
    assert_not order.delivery_order_items.first.update(quantity: 4)
    assert_not order.destroy
  end

  test "database enforces tenant isolation recurrence uniqueness and execution trace uniqueness" do
    order = build_order(delivery_schedule: delivery_schedules(:tuesday))
    order.save!
    assert_raises ActiveRecord::InvalidForeignKey do
      DeliveryOrder.transaction(requires_new: true) { order.update_columns(customer_id: customers(:other_company).id) }
    end
    assert_raises ActiveRecord::RecordNotUnique do
      DeliveryOrder.transaction(requires_new: true) do
        DeliveryOrder.insert_all!([ order.attributes.except("id").merge("visit_id" => nil) ])
      end
    end
    item = order.delivery_order_items.first
    assert_raises ActiveRecord::InvalidForeignKey do
      DeliveryOrderItem.transaction(requires_new: true) { item.update_columns(product_id: products(:almonds).id) }
    end
  end
end
