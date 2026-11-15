require "test_helper"

class DeliveryFollowUpTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @company = companies(:one)
    @order = DeliveryOrderGenerator.call(company: @company, date: "2026-11-17").first
    @run = @company.delivery_runs.new(name: "Incidencias", scheduled_date: @order.scheduled_date, driver: users(:driver), status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ @order.id ])
    @visit = @order.reload.visit
  end

  test "admin failed confirmation is audited and can be followed up once without replacing history" do
    patch delivery_run_visit_path(@run, @visit), params: { visit: { status: "not_attended", notes: "No atendió" } }
    assert_redirected_to delivery_run_path(@run)
    assert_equal users(:one), @visit.reload.confirmed_by
    assert @visit.confirmed_at
    assert_equal 0, @visit.delivery_items.first.delivered_quantity
    snapshot = @visit.attributes
    assert @order.reload.needs_attention?
    get delivery_orders_path, params: { status: "intervention" }
    assert_select "tr#delivery_order_#{@order.id}", count: 1
    get delivery_orders_path, params: { status: "unplanned" }
    assert_select "tr#delivery_order_#{@order.id}", count: 0
    get delivery_order_path(@order)
    assert_select "form[action=?]", reschedule_delivery_order_path(@order)
    assert_select "strong", text: "Mercadería no entregada"
    assert_difference "DeliveryOrder.count", 1 do
      2.times do
        post reschedule_delivery_order_path(@order), params: { date: "2026-11-18" }
        assert_response :see_other
      end
    end
    successor = @order.reload.rescheduled_order
    assert_redirected_to delivery_order_path(successor)
    assert_equal [ BigDecimal("20") ], successor.delivery_order_items.pluck(:quantity)
    assert_nil successor.visit_id
    assert_equal snapshot, @visit.reload.attributes
    get delivery_orders_path, params: { status: "intervention" }
    assert_select "tr#delivery_order_#{@order.id}", count: 0
    get delivery_orders_path, params: { status: "needs_attention" }
    assert_select "tr#delivery_order_#{@order.id}", count: 1
    get delivery_order_path(successor)
    assert_select "a[href=?]", delivery_order_path(@order)
  end

  test "failed admin outcomes reject positive quantities and repeated edits preserve audit" do
    patch delivery_run_visit_path(@run, @visit), params: { visit: { status: "closed", delivery_items_attributes: [ { id: @visit.delivery_items.first.id, delivered_quantity: 2 } ] } }
    assert_response :unprocessable_entity
    assert @visit.reload.pending?
    patch delivery_run_visit_path(@run, @visit), params: { visit: { status: "closed" } }
    assert_response :see_other
    snapshot = @visit.reload.attributes
    sign_in_as users(:supervisor)
    patch delivery_run_visit_path(@run, @visit), params: { visit: { status: "rescheduled", notes: "Sobrescribir" } }
    assert_response :unprocessable_entity
    assert_equal snapshot, @visit.reload.attributes
  end

  test "rescheduling rejects invalid dates and unauthorized or foreign requests" do
    patch delivery_run_visit_path(@run, @visit), params: { visit: { status: "closed" } }
    assert_no_difference "DeliveryOrder.count" do
      [ "invalid", "2026-11-17", "2026-11-16" ].each do |date|
        post reschedule_delivery_order_path(@order), params: { date: date }
        assert_redirected_to delivery_order_path(@order)
      end
      sign_in_as users(:two)
      post reschedule_delivery_order_path(@order), params: { date: "2026-11-18" }
      assert_response :not_found
      sign_in_as users(:driver)
      post reschedule_delivery_order_path(@order), params: { date: "2026-11-18" }
      assert_response :forbidden
    end
  end
end
