require "test_helper"

class HistoricalOperatingDataTest < ActiveSupport::TestCase
  setup do
    @company = companies(:one)
    @driver = users(:driver)
    @product = products(:bread)
    @product.update!(unit_price: "12.3456", unit_cost: "4.125")
    @date = @company.local_date
  end

  def order(**extra)
    @company.delivery_orders.create!({ customer: customers(:one), scheduled_date: @date,
      delivery_order_items_attributes: [ { product: @product, quantity: 10 } ] }.merge(extra))
  end

  def plan(rows)
    run = @company.delivery_runs.new(name: "Datos históricos", scheduled_date: @date, driver: @driver, status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: run, order_ids: rows.map(&:id))
  end

  test "catalog changes cannot change snapshots values margins or rescheduled shortages" do
    original = order
    run = plan([ original ])
    line = original.delivery_order_items.first
    execution = original.reload.visit.delivery_items.first
    captured = line.commercial_captured_at
    @product.update!(unit_price: 100, unit_cost: 90, name: "Nombre actual")
    assert_equal BigDecimal("12.3456"), line.reload.unit_price
    assert_equal line.unit_price, execution.reload.unit_price
    assert_equal captured, line.commercial_captured_at
    DriverVisitRecorder.call(user: @driver, visit_id: original.visit_id, attributes: {
      status: "completed", items: [ { id: execution.id, delivered_quantity: "4" } ] })
    assert original.reload.closed?
    assert_not original.fully_delivered?
    valuation = DeliveryValuation.new(original.delivery_order_items)
    assert_equal BigDecimal("123.456"), valuation.requested_value
    assert_equal BigDecimal("49.3824"), valuation.delivered_value
    assert_equal BigDecimal("32.8824"), valuation.estimated_margin
    replacement = DeliveryOrderRescheduler.call(company: @company, order_id: original.id, date: @date + 1)
    assert_equal 6, replacement.delivery_order_items.first.quantity
    assert_equal BigDecimal("12.3456"), replacement.delivery_order_items.first.unit_price
    assert_equal captured, replacement.delivery_order_items.first.commercial_captured_at
    assert_not line.update(unit_price: 1)
    assert_not execution.update(unit_cost: 1)
    metrics = DeliveryMetrics.call([ original ])
    assert_equal 100, metrics[:closure_rate]
    assert_equal 0, metrics[:full_delivery_rate]
    assert run.reload.completed?
  end

  test "unknown historical values are not filled by backfill current prices or treated as zero" do
    original = order(delivery_order_items_attributes: [ { description: "Manual sin precio", unit: "pack", quantity: 2 } ])
    valuation = DeliveryValuation.new(original.delivery_order_items)
    assert_nil valuation.requested_value
    assert_nil valuation.delivered_value
    run = plan([ original ])
    assert_nil run.visits.first.delivery_items.first.unit_price
    zero = order(delivery_order_items_attributes: [ { description: "Bonificado", quantity: 1, unit: "pack", unit_price: 0, unit_cost: 0 } ])
    assert_equal 0, DeliveryValuation.new(zero.delivery_order_items).requested_value
    assert_not @product.update(unit_price: "1.23456")
    assert_not @product.update(unit_cost: "NaN")
    assert_not @company.update(currency: "USD")
  end

  test "status events are atomic authored immutable and survive removing a pending stop" do
    original = order
    run = plan([ original ])
    id = original.reload.visit_id
    AuditContext.set(user: users(:one), source: "manager") do
      DeliveryOrderEditor.call(order: original, cancel: true)
    end
    events = @company.delivery_status_events.where(delivery_order_id: original.id).order(:id)
    assert_equal %w[pending cancelled], events.pluck(:to_status)
    assert_equal users(:one).id, events.last.user_id
    assert_equal "pending", events.last.from_status
    assert_not Visit.exists?(id)
    assert @company.delivery_status_events.where(visit_id: id).exists?
    assert_not events.last.update(to_status: "completed")
    assert_raises(ActiveRecord::RecordInvalid) { original.reload.update!(status: :completed) }
    assert_equal 2, events.count
  end

  test "delivered movements use actual quantities exactly once and load remains unknown until recorded" do
    original = order
    run = plan([ original ])
    visit = original.reload.visit
    DriverVisitRecorder.call(user: @driver, visit_id: visit.id, attributes: {
      status: "completed", items: [ { id: visit.delivery_items.first.id, delivered_quantity: "4" } ] })
    movement = run.run_stock_movements.sole
    assert_equal "delivery", movement.kind
    assert_equal 4, movement.quantity
    assert_equal @driver.id, movement.user_id
    RunStockRecorder.record_delivery(visit.reload)
    assert_equal 1, run.run_stock_movements.count
    assert_nil RunStockBalance.call(run).sole[:balance]
    attrs = { operation_id: SecureRandom.uuid, kind: "load", product_id: @product.id, quantity: "10" }
    first = RunStockRecorder.call(user: users(:one), run_id: run.id, attributes: attrs)
    assert_equal first, RunStockRecorder.call(user: users(:one), run_id: run.id, attributes: attrs)
    RunStockRecorder.call(user: users(:one), run_id: run.id, attributes: { operation_id: SecureRandom.uuid, kind: "return", product_id: @product.id, quantity: "6" })
    balance = RunStockBalance.call(run).sole
    assert_equal 0, balance[:balance]
    assert_equal 4, balance[:totals]["delivery"]
    assert_not movement.destroy
  end

  test "costs support idempotent actual and estimated entries reversals and explicit closure" do
    original = order
    run = plan([ original ])
    data = { operation_id: SecureRandom.uuid, category: "vehicle", description: "Uso vehículo", vehicle_label: "AB123CD", amount: "10.125", estimated: true }
    cost = RunCostRecorder.call(user: users(:one), run_id: run.id, attributes: data)
    assert_equal cost, RunCostRecorder.call(user: users(:one), run_id: run.id, attributes: data)
    assert_raises(ArgumentError) { RunCostRecorder.call(user: users(:one), run_id: run.id, attributes: data.merge(amount: "20")) }
    assert_raises(ArgumentError) { RunCostRecorder.close(user: users(:one), run_id: run.id) }
    DriverVisitRecorder.call(user: @driver, visit_id: original.reload.visit_id, attributes: { status: "closed", notes: "Cerrado" })
    assert_raises(ArgumentError) { RunCostRecorder.close(user: users(:one), run_id: run.id) }
    reversal = RunCostRecorder.reverse(user: users(:one), run_id: run.id, cost_id: cost.id)
    assert_equal(-cost.amount, reversal.amount)
    assert_equal reversal, RunCostRecorder.reverse(user: users(:one), run_id: run.id, cost_id: cost.id)
    actual = RunCostRecorder.call(user: users(:one), run_id: run.id, attributes: data.merge(operation_id: SecureRandom.uuid, estimated: false, amount: "8"))
    RunCostRecorder.close(user: users(:one), run_id: run.id)
    assert_equal users(:one).id, run.reload.costs_closed_by_id
    assert_raises(ActiveRecord::RecordInvalid) { RunCostRecorder.call(user: users(:one), run_id: run.id, attributes: data.merge(operation_id: SecureRandom.uuid)) }
    assert_not actual.update(amount: 0)
    assert_not run.update(costs_closed_at: nil, costs_closed_by_id: nil)
  end

  test "unknown legacy execution cannot produce zero delivered quantity or a known truck balance" do
    original = order
    run = plan([ original ])
    visit = original.reload.visit
    # Reconstruct an old completed visit whose quantity was never recorded.
    visit.update_columns(status: "completed")
    RunStockRecorder.call(user: users(:one), run_id: run.id, attributes: { operation_id: SecureRandom.uuid,
      kind: "load", product_id: @product.id, quantity: "10" })
    row = RunStockBalance.call(run).sole
    assert_nil row[:totals]["delivery"]
    assert_nil row[:balance]
    visit.delivery_items.first.update_columns(delivered_quantity: 0)
    row = RunStockBalance.call(run.reload).sole
    assert_equal 0, row[:totals]["delivery"]
    assert_equal 10, row[:balance]
  end
end
