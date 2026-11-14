require "test_helper"

class DeliveryManagementTest < ActiveSupport::TestCase
  test "SKU is unique only inside its company and blanks normalize to null" do
    duplicate = companies(:one).products.new(name: "Otro pan", sku: " PAN-01 ", unit: "pack")
    assert_not duplicate.valid?
    assert duplicate.errors[:sku].any?
    duplicate.company = companies(:two)
    assert duplicate.valid?
    duplicate.sku = " "
    assert_nil duplicate.sku
    assert duplicate.save
    assert companies(:two).products.create!(name: "Sin código", sku: "", unit: "unit")
  end

  test "catalog validates units and package pairs without converting deliveries" do
    product = products(:flour)
    assert_equal "bag", product.unit
    assert_equal 25, product.package_content_quantity
    product.unit = "pallet"
    assert_not product.valid?
    product.unit = "bag"
    product.package_content_quantity = nil
    assert_not product.valid?
    product.package_content_quantity = "0.1234"
    assert_not product.valid?
    product.package_content_quantity = 2.5
    product.package_content_unit = "box"
    assert_not product.valid?
  end

  test "manual schedule items validate positive quantities precision and discrete units" do
    item = delivery_schedules(:tuesday).delivery_schedule_items.build(description: "Harina especial", unit: "bag", quantity: 2)
    assert item.save
    assert_nil item.product_id
    assert_equal companies(:one), item.company
    [ 0, -1, "no", "1.5", "1.0001" ].each do |quantity|
      item.quantity = quantity
      assert_not item.valid?, "discrete quantity #{quantity} must fail"
    end
    item.unit = "kg"
    item.quantity = "1.125"
    assert item.valid?
    item.quantity = "1.1234"
    assert_not item.valid?
    item.unit = "invalid"
    assert_not item.valid?
  end

  test "weekly schedules accept ISO weekdays date boundaries and exclusive time forms" do
    schedule = delivery_schedules(:tuesday)
    assert schedule.valid?
    schedule.weekday = 0
    assert_not schedule.valid?
    schedule.weekday = 7
    schedule.ends_on = schedule.starts_on - 1
    assert_not schedule.valid?
    schedule.ends_on = schedule.starts_on
    assert schedule.valid?
    schedule.window_start = "08:00"
    schedule.window_end = "12:00"
    assert_not schedule.valid?
    schedule.preferred_time = nil
    assert schedule.valid?
    schedule.window_end = "07:00"
    assert_not schedule.valid?
    schedule.window_end = nil
    assert_not schedule.valid?
    assert_equal 2, customers(:one).delivery_schedules.count
  end

  test "all tenant associations reject references to another company" do
    schedule = delivery_schedules(:tuesday)
    schedule.customer = customers(:other_company)
    assert_not schedule.valid?
    item = delivery_schedule_items(:bread)
    item.product = products(:almonds)
    assert_not item.valid?
    item.product = products(:bread)
    item.delivery_schedule = delivery_schedules(:monday)
    assert_not item.valid?
    run = companies(:one).delivery_runs.new(name: "Reparto", scheduled_date: Date.current, driver: users(:two))
    assert_not run.valid?
    run.driver = users(:one)
    assert_not run.valid?, "administrator cannot be assigned as driver"
    run.driver = users(:driver)
    assert run.save
    visit = run.visits.new(customer: customers(:other_company))
    assert_not visit.valid?
    visit.customer = customers(:one)
    visit.delivery_schedule = delivery_schedules(:friday)
    assert visit.save
    visit.delivery_schedule = delivery_schedules(:monday)
    assert_not visit.valid?
    delivery = visit.delivery_items.new(product: products(:almonds), planned_quantity: 2)
    assert_not delivery.valid?
    delivery.company = companies(:two)
    assert_not delivery.valid?
  end

  test "inactive products cannot be newly selected and existing snapshots survive catalog edits" do
    item = delivery_schedules(:tuesday).delivery_schedule_items.build(product: products(:inactive), quantity: 2)
    assert_not item.valid?
    products(:bread).update!(active: false, name: "Nuevo nombre", unit: "box")
    existing = delivery_schedule_items(:bread)
    assert existing.update(quantity: 30)
    assert_equal "Pan lactal", existing.description
    assert_equal "pack", existing.unit
    run = planned_run(company: companies(:one), date: "2026-11-17")
    assert_equal "pack", run.visits.first.delivery_items.first.unit
  end

  test "optional product references must exist when provided" do
    item = delivery_schedules(:tuesday).delivery_schedule_items.build(product_id: -1, description: "Manual", unit: "kg", quantity: 1)
    assert_not item.valid?
    assert_includes item.errors[:product], "no existe"
    item.product_id = nil
    assert item.valid?
  end

  test "partial deliveries preserve planned quantities and distinguish nil from zero" do
    visit = planned_run(company: companies(:one), date: "2026-11-17").visits.first
    item = visit.delivery_items.first
    assert_nil item.delivered_quantity
    assert_nil item.difference
    item.update!(delivered_quantity: 18)
    assert_equal 20, item.planned_quantity
    assert_equal(-2, item.difference)
    assert_equal 20, delivery_schedule_items(:bread).reload.quantity
    item.update!(delivered_quantity: 0)
    assert_equal 0, item.delivered_quantity
    item.delivered_quantity = -1
    assert_not item.valid?
    item.delivered_quantity = "0.5"
    assert_not item.valid?
    item.delivered_quantity = ""
    assert item.valid?
    assert_nil item.delivered_quantity
    item.update!(delivered_quantity: 18)
    visit.update!(status: :completed)
    assert visit.completed_at
  end

  test "database rejects cross tenant references even without validations" do
    assert_raises ActiveRecord::InvalidForeignKey do
      DeliverySchedule.transaction(requires_new: true) do
        delivery_schedules(:tuesday).update_columns(customer_id: customers(:other_company).id)
      end
    end
    assert_raises ActiveRecord::InvalidForeignKey do
      DeliveryScheduleItem.transaction(requires_new: true) do
        delivery_schedule_items(:bread).update_columns(product_id: products(:almonds).id)
      end
    end
    assert_raises ActiveRecord::StatementInvalid do
      Product.transaction(requires_new: true) do
        products(:bread).update_columns(unit: "pallet")
      end
    end
    assert_raises ActiveRecord::RecordNotUnique do
      Product.transaction(requires_new: true) do
        products(:pizza).update_columns(sku: products(:bread).sku)
      end
    end
  end

  test "recurring hours retain local wall clock values in different company zones" do
    company = companies(:one)
    company.update!(time_zone: "Pacific/Auckland")
    schedule = nil
    Time.use_zone(company.time_zone) do
      schedule = company.delivery_schedules.create!(customer: customers(:one), starts_on: "2026-01-01", weekday: 2, preferred_time: "09:00")
    end
    Time.use_zone("UTC") { assert_equal "09:00", schedule.reload.preferred_time.strftime("%H:%M") }
  end

  test "company time zone is valid and local dates use the company zone" do
    company = companies(:one)
    assert_equal "America/Argentina/Buenos_Aires", company.time_zone
    travel_to Time.utc(2026, 11, 17, 1, 0) do
      assert_equal Date.new(2026, 11, 16), company.local_date
    end
    company.time_zone = "Invalid/Nowhere"
    assert_not company.valid?
  end
end
