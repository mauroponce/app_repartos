require "test_helper"
require_relative "../test_helpers/workflow_test_helper"

class DeliveryReportsTest < ActiveSupport::TestCase
  include WorkflowTestHelper

  test "multiple orders in one visit retain independent outcomes without inflating visits" do
    full = workflow_order
    partial = workflow_order(rows: [ { description: "Harina", quantity: 5, unit: "kg" } ])
    run = workflow_plan([ full, partial ])
    assert_equal 1, run.visits.count
    workflow_finish(run.visits.first, quantities: [ 10, 2 ])
    report = DeliveryReports.new(ReportFilter.new(companies(:one), period: "7"))
    assert_equal 2, report.counts[:programmed]
    assert_equal 1, report.counts[:visits]
    assert_equal 1, report.counts[:complete]
    assert_equal 1, report.counts[:partial]
    assert_equal 0, report.counts[:failed]
    assert_equal 50.0, report.counts[:fulfillment]
    assert_equal 3, report.shortages.sole["missing"]
    assert_equal "kg", report.shortages.sole["unit"]
    assert_equal 2, report.daily.sum { |row| row["total"].to_i }
    assert_equal users(:driver).id, report.drivers.sole["driver_id"]
  end

  test "incompatible units and product shortages are never summed together" do
    order = workflow_order(rows: [ { product: products(:bread), quantity: 10 }, { description: "Harina", quantity: 5, unit: "kg" }, { description: "Cajas", quantity: 4, unit: "box" } ])
    run = workflow_plan([ order ])
    workflow_finish(run.visits.first, quantities: [ 8, 2, 1 ])
    report = DeliveryReports.new(ReportFilter.new(companies(:one)))
    assert_equal %w[box kg pack], report.shortages.map { |row| row["unit"] }.sort
    assert_equal [ 3, 3, 2 ], report.shortages.sort_by { |row| row["unit"] }.map { |row| row["missing"].to_i }
    filtered = DeliveryReports.new(ReportFilter.new(companies(:one), product_id: products(:bread).id))
    assert_equal 1, filtered.counts[:partial]
    assert_equal [ "pack" ], filtered.shortages.pluck("unit")
  end

  test "failed zero unknown and pending outcomes remain distinct and cancellation is excluded" do
    orders = 4.times.map { workflow_order }
    orders.each_with_index do |order, index|
      run = workflow_plan([ order ])
      case index
      when 0 then workflow_finish(run.visits.first, status: "closed")
      when 1 then workflow_finish(run.visits.first, quantities: [ 0 ])
      when 2 then run.visits.first.update_columns(status: "completed")
      end
    end
    cancelled = workflow_order
    DeliveryOrderEditor.call(order: cancelled, cancel: true)
    counts = DeliveryReports.new(ReportFilter.new(companies(:one))).counts
    assert_equal 4, counts[:programmed]
    assert_equal 2, counts[:failed]
    assert_equal 1, counts[:unknown]
    assert_equal 1, counts[:pending]
    assert_equal 0.0, counts[:fulfillment]
  end

  test "company local dates equivalent periods filters and empty states are explicit" do
    company = companies(:one)
    company.update!(time_zone: "Pacific/Auckland")
    travel_to Time.utc(2026, 11, 15, 12, 30) do
      filter = ReportFilter.new(company, period: "7")
      assert_equal Date.new(2026, 11, 16), filter.end_on
      assert_equal filter.start_on - 1, filter.previous.end_on
      assert_equal 6, filter.previous.end_on - filter.previous.start_on
      report = DeliveryReports.new(filter)
      assert_nil report.counts[:fulfillment]
      assert_empty report.daily
      assert_empty report.shortages
      assert_empty report.drivers
      assert_empty report.details
      assert_raises(ActiveRecord::RecordNotFound) { ReportFilter.new(company, customer_id: customers(:other_company).id) }
      assert_raises(ArgumentError) { ReportFilter.new(company, start_on: "2020-01-01", end_on: "2026-01-01") }
    end
  end
end
