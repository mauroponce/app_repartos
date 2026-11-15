require "test_helper"

class DeliveryRunGeneratorTest < ActiveSupport::TestCase
  test "compatibility generator now produces only orders with historical units and idempotency" do
    products(:bread).update!(name: "Pan nuevo", unit: "box", active: false)
    orders = DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17")
    assert_equal 1, orders.size
    assert_nil orders.first.visit
    assert_equal "pack", orders.first.delivery_order_items.first.unit
    assert_equal "Pan lactal", orders.first.delivery_order_items.first.description
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryOrder.count", "DeliveryOrderItem.count" ] do
      DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17")
    end
  end

  test "only active schedules on their weekday and inclusive date range generate orders" do
    schedule = delivery_schedules(:tuesday)
    schedule.update!(active: false)
    assert_empty DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17")
    schedule.update!(active: true, starts_on: "2026-11-25", ends_on: "2026-12-01")
    assert_empty DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-24")
    assert_equal 1, DeliveryOrderGenerator.call(company: companies(:one), date: "2026-12-01").size
    assert_empty DeliveryOrderGenerator.call(company: companies(:one), date: "2026-12-08")
  end

  test "company local date is used when an instant is supplied" do
    order = DeliveryOrderGenerator.call(company: companies(:one), date: Time.utc(2026, 11, 18, 1)).first
    assert_equal Date.new(2026, 11, 17), order.scheduled_date
  end

  test "scenario B is a single order with two products and their execution copies" do
    orders = DeliveryOrderGenerator.call(company: companies(:two), date: "2026-11-16")
    assert_equal 1, orders.size
    assert_equal [ [ "kg", 10 ], [ "bag", 2 ] ], orders.first.delivery_order_items.pluck(:unit, :quantity)
    run = companies(:two).delivery_runs.new(name: "Mayorista", scheduled_date: "2026-11-16")
    DeliveryRunPlanner.call(company: companies(:two), delivery_run: run, order_ids: orders.map(&:id))
    assert_equal 1, run.visits.count
    assert_equal 2, run.visits.first.delivery_items.count
  end

  test "failure copying a later item rolls back generation of all new orders" do
    DeliveryOrderItem.before_create :abort_generator_test
    DeliveryOrderItem.define_method(:abort_generator_test) { throw :abort }
    assert_no_difference [ "DeliveryOrder.count", "DeliveryOrderItem.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) { DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17") }
    end
  ensure
    DeliveryOrderItem.skip_callback(:create, :before, :abort_generator_test)
    DeliveryOrderItem.remove_method(:abort_generator_test)
  end

  test "legacy completed visits backfill once preserving ids snapshots and delivered quantities" do
    company = companies(:one)
    run = company.delivery_runs.create!(name: "Histórica", scheduled_date: "2026-11-17", generation_key: "schedules:2026-11-17")
    visit = run.visits.create!(customer: customers(:one), delivery_schedule: delivery_schedules(:tuesday), position: 1, customer_name: "Nombre histórico", customer_address: "Dirección histórica")
    item = visit.delivery_items.create!(description: "Pan histórico", unit: "pack", planned_quantity: 25, delivered_quantity: 18)
    visit.update_columns(status: "completed", completed_at: Time.current)
    run.update!(status: :completed)
    delivery_schedule_items(:bread).update!(quantity: 30)
    assert_difference "DeliveryOrder.count", 1 do
      assert_no_difference [ "Visit.count", "DeliveryItem.count", "DeliveryRun.count" ] do
        DeliveryOrderGenerator.call(company: company, date: "2026-11-17")
      end
    end
    order = company.delivery_orders.last
    assert order.needs_attention?
    assert_nil order.preferred_time
    assert_equal visit, order.visit
    assert_equal "Nombre histórico", order.customer_name
    assert_equal "Dirección histórica", order.customer_address
    assert_equal 25, order.delivery_order_items.first.quantity
    assert_equal item.id, order.delivery_order_items.first.delivery_item.id
    assert_equal 18, item.reload.delivered_quantity
    assert_no_difference [ "DeliveryOrder.count", "DeliveryOrderItem.count" ] do
      assert_equal 0, DeliveryOrderBackfill.call(company: company)
      DeliveryOrderGenerator.call(company: company, date: "2026-11-17")
    end
  end

  test "legacy duplicates and empty visits do not generate duplicate obligations" do
    company = companies(:one)
    2.times do
      run = company.delivery_runs.create!(name: "Histórica", scheduled_date: "2026-11-17")
      visit = run.visits.create!(customer: customers(:one), delivery_schedule: delivery_schedules(:tuesday), position: 1)
      visit.delivery_items.create!(description: "Pan", unit: "pack", planned_quantity: 20)
    end
    assert_equal 1, DeliveryOrderGenerator.call(company: company, date: "2026-11-17").size
    assert_equal 2, company.visits.count
    run = company.delivery_runs.create!(name: "Vacía", scheduled_date: "2026-11-24")
    run.visits.create!(customer: customers(:one), delivery_schedule: delivery_schedules(:tuesday), position: 1)
    assert_empty DeliveryOrderGenerator.call(company: company, date: "2026-11-24")
  end

  test "backfill preserves failed and unknown historical execution without inventing authors or quantities" do
    company = companies(:one)
    [ [ "closed", nil ], [ "not_attended", 0 ], [ "rescheduled", nil ], [ "completed", nil ] ].each_with_index do |(status, quantity), index|
      date = Date.new(2026, 11, 17) + index.weeks
      run = company.delivery_runs.create!(name: "Legado #{status}", scheduled_date: date)
      visit = run.visits.create!(customer: customers(:one), delivery_schedule: delivery_schedules(:tuesday), position: 1)
      item = visit.delivery_items.create!(description: "Histórico", unit: "pack", planned_quantity: 20, delivered_quantity: quantity)
      visit.update_columns(status: status)
      original_visit = visit.attributes
      original_item = item.attributes.except("delivery_order_item_id")
      assert_equal 1, DeliveryOrderBackfill.call(company: company, visit_ids: [ visit.id ])
      order = visit.delivery_orders.first
      assert order.needs_attention?
      assert_equal quantity.nil? ? "unknown" : "none", order.fulfillment_result
      assert_equal original_visit, visit.reload.attributes
      assert_equal original_item, item.reload.attributes.except("delivery_order_item_id")
      assert_equal 0, DeliveryOrderBackfill.call(company: company, visit_ids: [ visit.id ])
    end
  end
end
