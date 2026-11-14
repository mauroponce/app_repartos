require "test_helper"

class DeliveryRunGeneratorTest < ActiveSupport::TestCase
  test "scenario A includes Tuesday bread and excludes Friday pizza" do
    run = DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17")
    assert_nil run.driver
    assert run.draft?
    assert_equal 1, run.visits.count
    visit = run.visits.first
    assert_equal customers(:one), visit.customer
    assert_equal delivery_schedules(:tuesday), visit.delivery_schedule
    assert_equal [ [ "Pan lactal", "pack", BigDecimal("20") ] ], visit.delivery_items.pluck(:description, :unit, :planned_quantity)
    assert_nil visit.delivery_items.first.delivered_quantity
    friday = DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-20", driver: users(:driver))
    assert friday.assigned?
    assert_equal "Pizzetas", friday.visits.first.delivery_items.first.description
  end

  test "scenario B copies kilograms and bags as independent quantities" do
    run = DeliveryRunGenerator.call(company: companies(:two), date: "2026-11-16")
    items = run.visits.first.delivery_items.index_by(&:description)
    assert_equal 2, items.size
    assert_equal "kg", items["Almendras"].unit
    assert_equal 10, items["Almendras"].planned_quantity
    assert_equal "bag", items["Harina bolsa 25 kg"].unit
    assert_equal 2, items["Harina bolsa 25 kg"].planned_quantity
  end

  test "scenario C schedule and catalog changes affect future copies without changing history" do
    past = DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17").visits.first
    delivery_schedule_items(:bread).update!(quantity: 30)
    customers(:one).update!(name: "Nombre nuevo", address: "Calle nueva")
    products(:bread).update!(name: "Pan nuevo")
    future = DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-24").visits.first
    assert_equal 20, past.delivery_items.first.planned_quantity
    assert_equal 30, future.delivery_items.first.planned_quantity
    assert_equal "Pan lactal", past.delivery_items.first.description
    assert_equal "Almacén San Martín", past.reload.customer_name
    assert_equal "San Martín 123, Adrogué", past.customer_address
    assert_equal "Nombre nuevo", future.customer_name
  end

  test "generation retries preserve edits and do not duplicate runs visits or items" do
    first = DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17")
    item = first.visits.first.delivery_items.first
    item.update!(planned_quantity: 25, delivered_quantity: 18)
    delivery_schedule_items(:bread).update!(quantity: 30)
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      assert_equal first, DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17")
      DeliveryRunGenerator.call(company: companies(:one), date: first.scheduled_date, delivery_run: first)
    end
    assert_equal 25, item.reload.planned_quantity
    assert_equal 18, item.delivered_quantity
  end

  test "manual visits coexist with several schedules for the same customer and weekday" do
    schedule = companies(:one).delivery_schedules.create!(customer: customers(:one), weekday: 2, starts_on: "2026-01-01", preferred_time: "15:00")
    schedule.delivery_schedule_items.create!(description: "Especial", quantity: 2, unit: "bag")
    run = companies(:one).delivery_runs.create!(name: "Manual", scheduled_date: "2026-11-17")
    manual = run.visits.create!(customer: customers(:one), position: 1)
    manual.delivery_items.create!(description: "Adicional", unit: "unit", planned_quantity: 1)
    DeliveryRunGenerator.call(company: companies(:one), date: run.scheduled_date, delivery_run: run)
    assert_equal 3, run.visits.count
    assert_nil manual.delivery_schedule_id
    assert_equal 3, run.visits.distinct.count(:position)
  end

  test "only active schedules within inclusive validity dates are generated" do
    schedule = delivery_schedules(:tuesday)
    schedule.update!(active: false)
    assert_empty DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17").visits
    schedule.update!(active: true, starts_on: "2026-11-25", ends_on: "2026-12-01")
    assert_empty DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-24").visits
    assert_equal 1, DeliveryRunGenerator.call(company: companies(:one), date: "2026-12-01").visits.count
    assert_empty DeliveryRunGenerator.call(company: companies(:one), date: "2026-12-08").visits
  end

  test "driver tenant mismatch aborts the entire generation" do
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      assert_raises ActiveRecord::RecordInvalid do
        DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17", driver: users(:two))
      end
    end
  end

  test "failures while copying items roll back the run and all visits" do
    # A failed item save must roll back the run and every already copied row.
    DeliveryItem.before_create :abort_generator_test
    DeliveryItem.define_method(:abort_generator_test) { throw :abort }
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      assert_raises ActiveRecord::RecordInvalid do
        DeliveryRunGenerator.call(company: companies(:one), date: "2026-11-17")
      end
    end
  ensure
    DeliveryItem.skip_callback(:create, :before, :abort_generator_test)
    DeliveryItem.remove_method(:abort_generator_test)
  end

  test "instant dates use tenant zone and generated dates cannot be moved" do
    run = DeliveryRunGenerator.call(company: companies(:one), date: Time.utc(2026, 11, 18, 1))
    assert_equal Date.new(2026, 11, 17), run.scheduled_date
    assert_not run.update(scheduled_date: "2026-11-18")
    assert_equal "schedules:2026-11-17", run.generation_key
  end
end
