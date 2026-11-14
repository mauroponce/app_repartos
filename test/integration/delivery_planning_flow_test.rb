require "test_helper"

class DeliveryPlanningFlowTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "scenario A generate select organize assign and complete partial execution" do
    post generate_delivery_orders_path, params: { date: "2026-11-17" }
    order = companies(:one).delivery_orders.last
    assert order.pending?
    assert_nil order.visit
    get new_delivery_run_path, params: { order_ids: [ order.id ] }
    assert_response :success
    assert_select ".planning-steps button", count: 4
    assert_select "input[name='order_ids[]'][checked]", count: 1
    post delivery_runs_path, params: { delivery_run: { name: "Zona Sur", scheduled_date: "2026-11-17", driver_id: users(:driver).id, status: "assigned" }, order_ids: [ order.id ], ordered_order_ids: [ order.id ] }
    run = companies(:one).delivery_runs.last
    assert_redirected_to delivery_run_path(run)
    assert run.assigned?
    assert_equal users(:driver), run.driver
    assert_equal 1, run.delivery_orders.count
    assert_equal 1, run.visits.count
    assert_equal 1, run.visits.first.delivery_items.count
    assert_equal run.id, order.reload.visit.delivery_run_id
    follow_redirect!
    assert_select "a[href=?]", delivery_order_path(order)
    get available_delivery_runs_path, params: { date: "2026-11-17" }
    assert_select "input[name='order_ids[]']", count: 0
    visit = run.visits.first
    item = visit.delivery_items.first
    patch delivery_run_visit_path(run, visit), params: { visit: { status: "completed", delivery_items_attributes: [ { id: item.id, delivered_quantity: "18", planned_quantity: "1000" } ] } }
    assert_redirected_to delivery_run_path(run)
    assert_equal 20, item.reload.planned_quantity
    assert_equal 18, item.delivered_quantity
    assert_equal 20, order.delivery_order_items.first.quantity
    assert_equal 20, delivery_schedule_items(:bread).reload.quantity
    get delivery_order_path(order)
    assert_select "td", text: "18"
    assert_select "td", text: "-2"
    assert order.reload.completed?
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      post delivery_runs_path, params: { delivery_run: { name: "Duplicada", scheduled_date: "2026-11-17" }, order_ids: [ order.id ] }
      assert_response :unprocessable_entity
    end
    patch delivery_run_visit_path(run, visit), params: { visit: { status: "pending", delivery_items_attributes: [ { id: item.id, delivered_quantity: "0" } ] } }
    assert_response :unprocessable_entity
    assert_equal 18, item.reload.delivered_quantity
  end

  test "bulk selection explains incompatible dates instead of silently dropping deliveries" do
    first = DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17").first
    second = DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-24").first
    get new_delivery_run_path, params: { order_ids: [ first.id, second.id ] }
    assert_redirected_to delivery_orders_path
    follow_redirect!
    assert_select "[role=alert]", text: /misma fecha/
  end

  test "route endpoints add remove reorder filter and validate dates and tenants" do
    orders = DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17")
    run = companies(:one).delivery_runs.create!(name: "Sur", scheduled_date: "2026-11-17")
    post add_orders_delivery_run_path(run), params: { order_ids: orders.map(&:id) }
    assert_redirected_to delivery_run_path(run)
    visit = run.visits.first
    post delivery_run_visits_path(run), params: { visit: { customer_id: customers(:one).id, position: 2 } }
    assert_redirected_to delivery_run_path(run)
    manual = run.visits.last
    patch reorder_delivery_run_path(run), params: { visit_ids: [ manual.id, visit.id ] }
    assert_equal [ manual.id, visit.id ], run.visits.reload.pluck(:id)
    patch delivery_run_path(run), params: { delivery_run: { driver_id: users(:driver).id, status: "assigned" } }
    assert_equal users(:driver), run.reload.driver
    get delivery_runs_path, params: { date: "2026-11-17", driver_id: users(:driver).id, status: "assigned" }
    assert_select ".entity-card", count: 1
    get delivery_runs_path, params: { status: "completed" }
    assert_select ".entity-card", count: 0
    patch delivery_run_path(run), params: { delivery_run: { scheduled_date: "2026-11-18" } }
    assert_response :unprocessable_entity
    delete remove_order_delivery_run_path(run, order_id: orders.first.id)
    assert_redirected_to delivery_run_path(run)
    assert_nil orders.first.reload.visit_id
    assert_equal [ manual.id ], run.visits.reload.pluck(:id)
    foreign = DeliveryOrderGenerator.call(company: companies(:two), date: "2026-11-16").first
    post add_orders_delivery_run_path(run), params: { order_ids: [ foreign.id ] }
    assert_response :not_found
  end
end
