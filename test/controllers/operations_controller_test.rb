require "test_helper"

class OperationsControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @company = companies(:one)
    @order = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @company.local_date, window_start: "08:00", window_end: "09:00",
      delivery_order_items_attributes: [ { description: "Pan", unit: "pack", quantity: 10 } ])
    @run = @company.delivery_runs.new(name: "En vivo", scheduled_date: @company.local_date, driver: users(:driver), status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ @order.id ])
  end

  test "management sees tenant snapshot and delivery updates broadcast invalidation" do
    sign_in_as users(:one)
    travel_to @company.local_date.in_time_zone(@company.time_zone).change(hour: 12) do
      get operations_path
      assert_response :success
      assert_select "[data-count=pending]", text: "1"
      assert_select ".operations-alerts", text: /1 entregas fuera de horario/
      assert_select "turbo-cable-stream-source", count: 1
      assert_select "head meta[name=turbo-cache-control][content=no-cache]", count: 1
      assert_no_match "Comercio Privado Norte", response.body
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_broadcasts(Turbo::StreamsChannel.verified_stream_name(Turbo::StreamsChannel.signed_stream_name([ @company, :operations ])), 1) do
        @order.update!(notes: "Aviso")
      end
      DriverVisitRecorder.call(user: users(:driver), visit_id: @order.reload.visit_id, attributes: { status: "closed", notes: "Cerrado" })
      get operations_snapshot_path, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_select "turbo-stream[action=replace][target=operations-board]"
      assert_select "[data-count=failed]", text: "1"
      assert_select "[data-count=pending]", text: "0"
    end
  end

  test "drivers and foreign tenants cannot manage orders" do
    sign_in_as users(:driver)
    get operations_path
    assert_response :forbidden
    get operations_snapshot_path
    assert_response :forbidden
    sign_in_as users(:two)
    post operations_dispatch_path(order_id: @order.id), params: { dispatch: {
      revision: OperationsDispatch.revision(@order.reload), target_run_id: "", date: @company.local_date + 1, reason: "Otro día" } }
    assert_response :not_found
  end

  test "supervisor reprograms from operations and audit is visible" do
    sign_in_as users(:supervisor)
    post operations_dispatch_path(order_id: @order.id), params: { dispatch: {
      revision: OperationsDispatch.revision(@order.reload), target_run_id: "", date: @company.local_date + 1, reason: "Pedido del cliente" } }
    assert_redirected_to operations_path
    follow_redirect!
    assert_select "[data-count=pending]", text: "0"
    assert_match "Pedido del cliente", response.body
    assert_equal @company.local_date + 1, @order.reload.scheduled_date
  end
end
