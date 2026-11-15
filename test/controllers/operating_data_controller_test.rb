require "test_helper"

class OperatingDataControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = companies(:one)
    @order = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @company.local_date,
      delivery_order_items_attributes: [ { product: products(:bread), quantity: 10, unit_price: "25.5", unit_cost: "10.1" } ])
    @run = @company.delivery_runs.new(name: "Datos", scheduled_date: @company.local_date, driver: users(:driver), status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ @order.id ])
    sign_in_as users(:one)
  end

  test "manager sees valuation costs stock and immutable status history" do
    get delivery_run_data_path(@run)
    assert_response :success
    assert_match "pedidos cerrados", response.body
    assert_match "entregados al 100%", response.body
    assert_match "Costos abiertos", response.body
    assert_equal "no-store", response.headers["Cache-Control"]
    values = { operation_id: SecureRandom.uuid, category: "fuel", amount: "10.5", description: "Carga combustible", estimated: "false" }
    assert_difference "DeliveryRunCost.count", 1 do
      post create_cost_delivery_run_data_path(@run), params: { cost: values }
      assert_redirected_to delivery_run_data_path(@run)
      post create_cost_delivery_run_data_path(@run), params: { cost: values }
    end
    assert_difference "RunStockMovement.count", 1 do
      post create_stock_delivery_run_data_path(@run), params: { movement: { operation_id: SecureRandom.uuid, kind: "load", product_id: products(:bread).id, quantity: 10 } }
      assert_redirected_to delivery_run_data_path(@run)
    end
    get delivery_order_path(@order)
    assert_match "ARS 255,00", response.body
    assert_match "Valores comerciales históricos", response.body
  end

  test "communications preserve evidence and default to no consent" do
    get customer_communications_path(customers(:one))
    assert_response :success
    assert_match "Sin autorización vigente", response.body
    attributes = { channel: "email", purpose: "operational", decision: "granted", evidence: "Respuesta del cliente por email" }
    assert_difference "CommunicationConsent.count", 1 do
      post customer_communications_path(customers(:one)), params: { consent: attributes }
      assert_redirected_to customer_communications_path(customers(:one))
      post customer_communications_path(customers(:one)), params: { consent: attributes }
    end
    follow_redirect!
    assert_match "Autorizado para el contacto actual", response.body
    assert_match "Respuesta del cliente por email", response.body
  end

  test "manager partial confirmation requires a structured reason and records the server clock" do
    visit = @order.reload.visit
    values = { status: "completed", receipt_version: 1,
      delivery_items_attributes: [ { id: visit.delivery_items.first.id, delivered_quantity: 4 } ] }
    assert_no_difference "RunStockMovement.count" do
      patch delivery_run_visit_path(@run, visit), params: { visit: values }
      assert_response :unprocessable_entity
    end
    assert visit.reload.pending?
    patch delivery_run_visit_path(@run, visit), params: { visit: values.merge(failure_reason: "shortage") }
    assert_redirected_to delivery_run_path(@run)
    assert_equal "server", visit.reload.recorded_at_source
    assert_not_nil visit.recorded_at
    assert @order.reload.closed?
    assert_not @order.fully_delivered?
    event = @company.delivery_status_events.where(visit_id: visit.id, to_status: "completed").sole
    assert_nil event.client_occurred_at
    assert_equal users(:one).id, event.user_id
  end

  test "driver and foreign company cannot access commercial data or change consents" do
    sign_in_as users(:driver)
    get delivery_run_data_path(@run)
    assert_response :forbidden
    get customer_communications_path(customers(:one))
    assert_response :forbidden
    sign_in_as users(:two)
    get delivery_run_data_path(@run)
    assert_response :not_found
    post customer_communications_path(customers(:one)), params: { consent: { channel: "sms", purpose: "marketing", decision: "granted", evidence: "x" } }
    assert_response :not_found
  end

  test "foreign product errors do not reveal another tenant prices or costs" do
    products(:almonds).update!(unit_price: "987654321.1234", unit_cost: "87654321.4321")
    post delivery_orders_path, params: { delivery_order: { customer_id: customers(:one).id, scheduled_date: @company.local_date,
      delivery_order_items_attributes: [ { product_id: products(:almonds).id, quantity: 1 } ] } }
    assert_response :unprocessable_entity
    assert_no_match "987654321", response.body
    assert_no_match "87654321", response.body
  end
end
