require "test_helper"

class OnboardingPwaTest < ActionDispatch::IntegrationTest
  test "driver can consult future published work but cannot execute it early or access another assignment" do
    company = companies(:one)
    date = company.local_date + 1
    run = company.delivery_runs.create!(name: "Mañana AMBA", scheduled_date: date, driver: users(:driver))
    order = company.delivery_orders.create!(customer: customers(:one), scheduled_date: date,
      delivery_order_items_attributes: [ { description: "Harina demo", unit: "bag", quantity: 2 } ])
    DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: [ order.id ])
    RoutePublication.use_manual!(user: users(:one), run: run)
    sign_in_as users(:driver)
    get repartidor_root_path
    assert_response :success
    assert_select "a[href=?]", repartidor_runs_path, text: "Próximas hojas asignadas"
    get repartidor_runs_path
    assert_response :success
    assert_select "a[href=?]", repartidor_run_path(run), text: /Mañana AMBA/
    get repartidor_run_path(run)
    assert_response :success
    assert_select "h1", "Mañana AMBA"
    assert_select "li", text: /Harina demo · 2 bolsa/
    assert_select "form", count: 0
    visit = run.visits.first
    patch repartidor_visit_path(visit), params: { visit: { status: "closed", notes: "Fuera de fecha" } }
    assert_response :conflict
    assert visit.reload.pending?
    sign_in_as users(:other_driver)
    get repartidor_run_path(run)
    assert_response :not_found
    patch repartidor_visit_path(visit), params: { visit: { status: "closed", notes: "Ajena" } }
    assert_response :not_found
  end

  test "future blocked publication stays invisible until explicitly published manually" do
    company = companies(:one)
    run = company.delivery_runs.create!(name: "Pendiente de publicación", scheduled_date: company.local_date + 1, driver: users(:driver), status: :assigned)
    publication = RoutePublication.create!(company: company, delivery_run: run, requested_by: users(:one), state: "failed")
    sign_in_as users(:driver)
    get repartidor_run_path(run)
    assert_response :not_found
    RoutePublication.use_manual!(user: users(:one), run: run)
    assert_equal "manual", publication.reload.state
    get repartidor_run_path(run)
    assert_response :success
  end
end
