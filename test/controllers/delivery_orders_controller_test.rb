require "test_helper"

class DeliveryOrdersControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  def attributes
    { customer_id: customers(:one).id, scheduled_date: "2026-11-17", preferred_time: "09:00", company_id: companies(:two).id,
      delivery_order_items_attributes: { "0" => { product_id: products(:bread).id, quantity: "20" }, "1" => { description: "Especial", unit: "kg", quantity: "1.125" } } }
  end

  def create_order
    post delivery_orders_path, params: { delivery_order: attributes }
    assert_response :see_other
    companies(:one).delivery_orders.last
  end

  test "create edit show manual merchandise and cancellation are transactional" do
    get new_delivery_order_path
    assert_response :success
    assert_select "[data-controller='nested-items']"
    assert_select "select[name='delivery_order[visit_id]']", count: 0
    order = nil
    assert_difference [ "DeliveryOrder.count" ], 1 do
      assert_difference "DeliveryOrderItem.count", 2 do
        order = create_order
      end
    end
    assert_equal companies(:one), order.company
    assert_nil order.visit
    follow_redirect!
    assert_select "td", text: "Especial"
    get edit_delivery_order_path(order)
    assert_response :success
    item = order.delivery_order_items.first
    patch delivery_order_path(order), params: { delivery_order: { notes: "Puntual", delivery_order_items_attributes: [ { id: item.id, quantity: 30 } ] } }
    assert_redirected_to delivery_order_path(order)
    assert_equal 30, item.reload.quantity
    post cancel_delivery_order_path(order)
    assert order.reload.cancelled?
    patch delivery_order_path(order), params: { delivery_order: { notes: "No" } }
    assert_response :unprocessable_entity
    assert_equal "Puntual", order.reload.notes
  end

  test "invalid merchandise and foreign references do not partially persist" do
    assert_no_difference [ "DeliveryOrder.count", "DeliveryOrderItem.count" ] do
      post delivery_orders_path, params: { delivery_order: attributes.deep_merge(delivery_order_items_attributes: [ { description: "Caja", unit: "box", quantity: "1.5" } ]) }
      assert_response :unprocessable_entity
      assert_select "[role=alert]"
      post delivery_orders_path, params: { delivery_order: attributes.merge(customer_id: customers(:other_company).id) }
      assert_response :unprocessable_entity
      post delivery_orders_path, params: { delivery_order: attributes.merge(delivery_order_items_attributes: [ { product_id: products(:almonds).id, quantity: 1 } ]) }
      assert_response :unprocessable_entity
    end
  end

  test "listing searches filters and bulk selection use real tenant data" do
    order = create_order
    foreign = DeliveryOrderGenerator.call(company: companies(:two), date: "2026-11-16").first
    get delivery_orders_path
    assert_response :success
    assert_select ".delivery-orders-table tbody tr", count: 1
    assert_select "input[name='order_ids[]'][value=?]", order.id.to_s
    assert_select "input[value=?]", foreign.id.to_s, count: 0
    [ { q: "Especial" }, { q: "San Martín" }, { date: "2026-11-17", customer_id: order.customer_id }, { status: "unplanned" } ].each do |filters|
      get delivery_orders_path, params: filters
      assert_select ".delivery-orders-table tbody tr", count: 1
    end
    get delivery_orders_path, params: { q: "%" }
    assert_select ".delivery-orders-table tbody tr", count: 0
    run = companies(:one).delivery_runs.new(name: "Ruta", scheduled_date: order.scheduled_date)
    DeliveryRunPlanner.call(company: companies(:one), delivery_run: run, order_ids: [ order.id ])
    get delivery_orders_path, params: { status: "unplanned" }
    assert_select ".delivery-orders-table tbody tr", count: 0
    get delivery_orders_path, params: { status: "assigned", delivery_run_id: run.id }
    assert_select ".delivery-orders-table tbody tr", count: 1
    assert_select "input[name='order_ids[]']", count: 0
  end

  test "generate recurrence retries create no route and cancellation remains idempotent" do
    assert_difference "DeliveryOrder.count", 1 do
      assert_no_difference [ "DeliveryRun.count", "Visit.count" ] do
        post generate_delivery_orders_path, params: { date: "2026-11-17" }
      end
    end
    assert_redirected_to delivery_orders_path(date: "2026-11-17")
    post cancel_delivery_order_path(companies(:one).delivery_orders.last)
    assert_no_difference "DeliveryOrder.count" do
      post generate_delivery_orders_path, params: { date: "2026-11-17" }
    end
    post generate_delivery_orders_path, params: { date: "invalid" }
    assert_redirected_to delivery_orders_path
  end

  test "tenant and role authorization covers all order endpoints" do
    foreign = DeliveryOrderGenerator.call(company: companies(:two), date: "2026-11-16").first
    [ delivery_order_path(foreign), edit_delivery_order_path(foreign) ].each do |path|
      get path
      assert_response :not_found
    end
    patch delivery_order_path(foreign), params: { delivery_order: { notes: "No" } }
    assert_response :not_found
    post cancel_delivery_order_path(foreign)
    assert_response :not_found
    sign_in_as users(:supervisor)
    get delivery_orders_path
    assert_response :success
    sign_in_as users(:driver)
    [ delivery_orders_path, new_delivery_order_path, available_delivery_runs_path(date: "2026-11-17") ].each do |path|
      get path
      assert_response :forbidden
    end
    assert_no_difference "DeliveryOrder.count" do
      post delivery_orders_path, params: { delivery_order: attributes }
      assert_response :forbidden
      post generate_delivery_orders_path, params: { date: "2026-11-17" }
      assert_response :forbidden
    end
  end
end
