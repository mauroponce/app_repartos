require "test_helper"

class DeliveryManagementControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "catalog list search and filter stay inside the tenant" do
    get products_path
    assert_response :success
    assert_select ".products-table tbody tr", count: 2
    assert_select "select[name=active] option[selected][value=true]", text: "Activos"
    assert_select ".products-table td", text: "Almendras", count: 0
    get products_path, params: { active: "" }
    assert_select ".products-table tbody tr", count: 3
    get products_path, params: { q: "PAN-01", active: "true" }
    assert_select ".products-table tbody tr", count: 1
    get products_path, params: { active: "false" }
    assert_select ".products-table tbody tr", count: 1
    get products_path, params: { q: "%" }
    assert_select ".products-table tbody tr", count: 0
    13.times { |i| companies(:one).products.create!(name: "Nuevo #{i}", unit: "kg") }
    get products_path, params: { q: "Nuevo" }
    assert_select ".products-table tbody tr", count: 13
    get products_path, params: { q: "Producto", active: "false" }, headers: { "Turbo-Frame" => "product-results" }
    assert_select "turbo-frame#product-results .products-table tbody tr", count: 1
    assert_select ".products-table td", text: "Producto retirado"
  end

  test "product detail is available only within the current company" do
    get products_path
    assert_select "tr#product_#{products(:bread).id} a[href=?][data-turbo-frame=modal]", product_path(products(:bread)), minimum: 1
    assert_select ".products-table button", text: /Desactivar|Activar/, count: 0
    get product_path(products(:bread)), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "dialog #product-detail-title", text: products(:bread).name
    assert_select "a[href=?]", edit_product_path(products(:bread)), text: /Editar producto/
    assert_select "a", text: "Volver a productos"
    get product_path(products(:almonds))
    assert_response :not_found
  end

  test "product create update toggle and errors preserve tenant and history" do
    get new_product_path
    assert_response :success
    assert_difference "companies(:one).products.count" do
      post products_path, params: { product: { name: "Semillas", unit: "kg", company_id: companies(:two).id } }
    end
    assert_redirected_to products_path
    patch product_path(products(:bread)), params: { product: { active: false, company_id: companies(:two).id } }
    assert_redirected_to products_path
    assert_not products(:bread).reload.active?
    assert_equal companies(:one), products(:bread).company
    get edit_product_path(products(:bread))
    assert_response :success
    post products_path, params: { product: { name: "", unit: "bad" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]"
    get edit_product_path(products(:almonds))
    assert_response :not_found
    patch product_path(products(:almonds)), params: { product: { name: "Robado" } }
    assert_response :not_found
  end

  test "customer detail and nested schedules support catalog manual items and updates" do
    get customer_path(customers(:one))
    assert_select "h2", text: "Entregas programadas"
    assert_select ".schedule-card", count: 2
    get new_customer_delivery_schedule_path(customers(:one))
    assert_response :success
    assert_select "select option", text: "Producto retirado", count: 0
    assert_select "template[data-nested-items-target=template]"
    assert_difference "DeliverySchedule.count" do
      assert_difference "DeliveryScheduleItem.count", 2 do
        post customer_delivery_schedules_path(customers(:one)), params: { delivery_schedule: schedule_attributes }
        assert_response :redirect, response.body
      end
    end
    schedule = customers(:one).delivery_schedules.order(:created_at).last
    assert_equal companies(:one), schedule.company
    assert_equal [ "kg", "pack" ], schedule.delivery_schedule_items.pluck(:unit).sort
    get edit_customer_delivery_schedule_path(customers(:one), schedule)
    assert_response :success
    item = schedule.delivery_schedule_items.first
    patch customer_delivery_schedule_path(customers(:one), schedule), params: { delivery_schedule: { active: false, delivery_schedule_items_attributes: { "0" => { id: item.id, _destroy: "1" } } } }
    assert_redirected_to customer_path(customers(:one))
    assert_not schedule.reload.active?
    assert_equal 1, schedule.delivery_schedule_items.count
  end

  test "schedule invalid times and foreign products fail without partial persistence" do
    assert_no_difference [ "DeliverySchedule.count", "DeliveryScheduleItem.count" ] do
      post customer_delivery_schedules_path(customers(:one)), params: { delivery_schedule: schedule_attributes.merge(window_start: "08:00", window_end: "07:00") }
    end
    assert_response :unprocessable_entity
    assert_no_difference "DeliverySchedule.count" do
      post customer_delivery_schedules_path(customers(:one)), params: { delivery_schedule: schedule_attributes.merge(delivery_schedule_items_attributes: [ { product_id: products(:almonds).id, quantity: 2 } ]) }
    end
    assert_response :unprocessable_entity
    get new_customer_delivery_schedule_path(customers(:other_company))
    assert_response :not_found
    get edit_customer_delivery_schedule_path(customers(:one), delivery_schedules(:monday))
    assert_response :not_found
  end

  test "planned run detail edit assignment and partial execution" do
    order = DeliveryOrderGenerator.call(company: companies(:one), date: "2026-11-17").first
    get new_delivery_run_path, params: { order_ids: [ order.id ] }
    assert_response :success
    assert_difference "DeliveryRun.count" do
      post delivery_runs_path, params: { delivery_run: { name: "Martes", scheduled_date: "2026-11-17" }, order_ids: [ order.id ] }
    end
    run = companies(:one).delivery_runs.last
    assert_redirected_to delivery_run_path(run)
    follow_redirect!
    assert_select "h2", text: /Almacén San Martín/
    assert_select "td", text: "Sin registrar"
    get delivery_runs_path
    assert_response :success
    get edit_delivery_run_path(run)
    assert_response :success
    patch delivery_run_path(run), params: { delivery_run: { driver_id: users(:driver).id, status: "assigned" } }
    assert_redirected_to delivery_run_path(run)
    assert_equal users(:driver), run.reload.driver
    visit = run.visits.first
    get edit_delivery_run_visit_path(run, visit)
    assert_response :success
    patch delivery_run_visit_path(run, visit), params: { visit: { status: "completed", delivery_items_attributes: [ { id: visit.delivery_items.first.id, delivered_quantity: "18" } ] } }
    assert_redirected_to delivery_run_path(run)
    assert_equal 18, visit.delivery_items.first.reload.delivered_quantity
    assert_equal 20, visit.delivery_items.first.planned_quantity
    assert_equal 20, delivery_schedule_items(:bread).reload.quantity
    follow_redirect!
    assert_select "td", text: "-2"
    assert visit.reload.completed_at
    assert order.reload.needs_attention?
  end

  test "manual runs and visits support manual products and invalid delivery feedback" do
    post delivery_runs_path, params: { delivery_run: { name: "Manual", scheduled_date: "2026-11-17" }, generate_schedules: "0" }
    run = companies(:one).delivery_runs.last
    assert_empty run.visits
    get new_delivery_run_visit_path(run)
    assert_response :success
    post delivery_run_visits_path(run), params: { visit: { customer_id: customers(:one).id, delivery_items_attributes: [ { description: "Especial", unit: "bag", planned_quantity: 2 } ] } }
    assert_redirected_to delivery_run_path(run)
    visit = run.visits.first
    assert_nil visit.delivery_schedule_id
    patch delivery_run_visit_path(run, visit), params: { visit: { delivery_items_attributes: [ { id: visit.delivery_items.first.id, delivered_quantity: -1 } ] } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]"
    assert_nil visit.delivery_items.first.reload.delivered_quantity
    orders = DeliveryOrderGenerator.call(company: companies(:one), date: run.scheduled_date)
    post add_orders_delivery_run_path(run), params: { order_ids: orders.map(&:id) }
    assert_redirected_to delivery_run_path(run)
    assert_equal 2, run.visits.count
  end

  test "run and visit paths cannot access another tenant or assign its users or products" do
    foreign_run = planned_run(company: companies(:two), date: "2026-11-16")
    [ delivery_run_path(foreign_run), edit_delivery_run_path(foreign_run), new_delivery_run_visit_path(foreign_run) ].each do |path|
      get path
      assert_response :not_found
    end
    post add_orders_delivery_run_path(foreign_run)
    assert_response :not_found
    post delivery_runs_path, params: { delivery_run: { name: "R", scheduled_date: "2026-11-17", driver_id: users(:two).id } }
    assert_response :not_found
    run = planned_run(company: companies(:one), date: "2026-11-17")
    get edit_delivery_run_visit_path(run, foreign_run.visits.first)
    assert_response :not_found
    patch delivery_run_visit_path(run, run.visits.first), params: { visit: { delivery_items_attributes: [ { description: "Robado", product_id: products(:almonds).id, planned_quantity: 2, unit: "kg" } ] } }
    assert_response :not_found
    assert_equal 1, run.visits.first.delivery_items.count
  end

  test "administrator and supervisor can manage while drivers are forbidden and guests redirected" do
    sign_in_as users(:supervisor)
    get products_path
    assert_response :success
    get delivery_runs_path
    assert_response :success
    get new_customer_delivery_schedule_path(customers(:one))
    assert_response :success
    run = planned_run(company: companies(:one), date: "2026-11-17")
    sign_in_as users(:driver)
    [ products_path, new_product_path, delivery_runs_path, new_delivery_run_path, new_product_import_path, template_product_imports_path, new_customer_delivery_schedule_path(customers(:one)), edit_delivery_run_visit_path(run, run.visits.first) ].each do |path|
      get path
      assert_response :forbidden
    end
    assert_no_difference [ "Product.count", "DeliverySchedule.count", "DeliveryRun.count" ] do
      post products_path, params: { product: { name: "No", unit: "kg" } }
      assert_response :forbidden
      post customer_delivery_schedules_path(customers(:one)), params: { delivery_schedule: schedule_attributes }
      assert_response :forbidden
      post delivery_runs_path, params: run_parameters
      assert_response :forbidden
    end
    sign_out
    get products_path
    assert_redirected_to new_session_path
    post delivery_runs_path, params: run_parameters
    assert_redirected_to new_session_path
  end

  private

  def schedule_attributes
    { weekday: 1, starts_on: "2026-11-01", preferred_time: "09:00", company_id: companies(:two).id,
      delivery_schedule_items_attributes: { "0" => { product_id: products(:bread).id, quantity: "20" }, "1" => { description: "Especial", quantity: "1.125", unit: "kg" } } }
  end

  def run_parameters
    { delivery_run: { name: "Martes", scheduled_date: "2026-11-17", company_id: companies(:two).id }, generate_schedules: "1" }
  end
end
