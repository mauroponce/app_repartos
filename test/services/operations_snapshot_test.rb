require "test_helper"

class OperationsSnapshotTest < ActiveSupport::TestCase
  test "zero quantity is failed partial delivery is separate and overdue uses company timezone" do
    company = companies(:one)
    date = company.local_date
    orders = 4.times.map do |index|
      company.delivery_orders.create!(customer: customers(:one), scheduled_date: date, preferred_time: "#{8 + index}:00",
        delivery_order_items_attributes: [ { description: "Pan", quantity: 10, unit: "pack" } ])
    end
    run = company.delivery_runs.new(name: "Contadores", scheduled_date: date, driver: users(:driver), status: :assigned)
    DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: orders.map(&:id))
    orders.first(3).zip([ "10", "4", "0" ]).each do |order, quantity|
      visit = order.reload.visit
      DriverVisitRecorder.call(user: users(:driver), visit_id: visit.id, attributes: {
        status: "completed", items: [ { id: visit.delivery_items.first.id, delivered_quantity: quantity } ] })
    end
    zone = ActiveSupport::TimeZone[company.time_zone]
    boundary = zone.local(date.year, date.month, date.day, 11)
    travel_to boundary do
      snapshot = OperationsSnapshot.new(company: company)
      assert_equal({ pending: 1, completed: 1, partial: 1, failed: 1 }, snapshot.counts)
      assert_empty snapshot.overdue
    end
    travel_to boundary + 1.minute do
      assert_equal [ orders.last.id ], OperationsSnapshot.new(company: company).overdue.map(&:id)
    end
  end

  test "locations of inactive foreign and finished drivers never enter map" do
    company = companies(:one)
    driver = users(:driver)
    run = company.delivery_runs.create!(name: "Activa", scheduled_date: company.local_date, driver: driver, status: :assigned)
    location = company.driver_locations.create!(user: driver, latitude: -34, longitude: -58, accuracy: 10, captured_at: Time.current)
    companies(:two).driver_locations.create!(user: users(:other_driver), latitude: -33, longitude: -57, accuracy: 10, captured_at: Time.current)
    assert_equal [ driver.id ], OperationsSnapshot.new(company: company).markers.pluck(:id)
    location.update!(captured_at: 3.minutes.ago)
    assert_not OperationsSnapshot.new(company: company).markers.first[:fresh]
    driver.update!(status: :inactive)
    assert_empty OperationsSnapshot.new(company: company).markers
    driver.update!(status: :active)
    run.update!(status: :completed)
    assert_empty OperationsSnapshot.new(company: company).markers
  end
end
