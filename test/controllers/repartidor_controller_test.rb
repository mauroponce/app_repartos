require "test_helper"

class RepartidorControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = companies(:one)
    @driver = users(:driver)
    @run = @company.delivery_runs.create!(name: "Ruta propia", scheduled_date: @company.local_date, driver: @driver, status: :assigned)
    @visit = @run.visits.create!(company: @company, customer: customers(:one), position: 1)
    @item = @visit.delivery_items.create!(description: "Bultos", unit: "box", planned_quantity: 3)
    sign_in_as @driver
  end

  test "visit forms carry the displayed snapshot and its matching authorization" do
    get repartidor_root_path
    assert_response :success
    assert_select "#visit-#{@visit.id} form[data-work-snapshot]" do |forms|
      data = JSON.parse(forms.first["data-work-snapshot"])
      proof = DriverWorkSnapshot.read(data.fetch("proof"))
      assert_equal @visit.id, data.fetch("id")
      assert_equal @visit.id, proof.fetch("visit_id")
      assert_equal @driver.id, proof.fetch("user_id")
      assert_equal DriverWorkSnapshot.revision(@visit.reload), proof.fetch("revision")
      assert_equal proof.fetch("revision"), data.fetch("revision")
      assert_equal data.except("id", "proof", "revision"), proof.fetch("snapshot")
      assert_equal [ @item.id ], data.fetch("items").pluck("id")
      assert_equal [ "3.0" ], data.fetch("items").pluck("planned_quantity")
    end
  end

  test "driver app requires an active driver session and admin pages hide admin navigation on denial" do
    get repartidor_root_path
    assert_response :success
    assert_select "nav.bottom-nav button", count: 5
    assert_select "a[href^='/admin']", count: 0
    assert_select "link[rel=manifest][href=?]", repartidor_manifest_path
    assert_includes response.headers["Cache-Control"], "no-store"
    get customers_path
    assert_response :forbidden
    assert_select ".sidebar", count: 0
    [ users(:one), users(:supervisor) ].each do |user|
      sign_in_as user
      get repartidor_root_path
      assert_redirected_to admin_root_path
      patch repartidor_visit_path(@visit), params: completed_params
      assert_redirected_to admin_root_path
    end
    sign_out
    get repartidor_root_path
    assert_redirected_to new_session_path
    sign_in_as @driver
    @driver.update!(status: :inactive)
    get repartidor_root_path
    assert_redirected_to new_session_path
  end

  test "only the drivers assigned published routes for today and their history are visible" do
    other = @company.users.create!(name: "Otro", email_address: "colleague@example.test", role: :driver, password: "Password-test-2026")
    [ [ @company, other, @company.local_date, :assigned ], [ companies(:two), users(:other_driver), @company.local_date, :assigned ],
      [ @company, @driver, @company.local_date + 1, :assigned ], [ @company, @driver, @company.local_date, :draft ],
      [ @company, @driver, @company.local_date, :cancelled ] ].each do |company, driver, date, status|
      run = company.delivery_runs.create!(name: "Ruta oculta #{status}", scheduled_date: date, driver: driver, status: status)
      get repartidor_root_path(run_id: run.id)
      assert_response :not_found
    end
    get repartidor_root_path
    assert_response :success
    assert_select ".delivery-item", count: 1
    assert_select ".delivery-info strong", text: customers(:one).name
    assert_no_match "Ruta oculta", response.body
  end

  test "empty route shows a usable empty state and profile" do
    @run.update!(driver: nil, status: :draft)
    get repartidor_root_path
    assert_response :success
    assert_select "h3", text: "Todavía no tenés una ruta para hoy"
    assert_select ".profile-card strong", text: @driver.name
    assert_select "form[action=?]", session_path
  end

  test "multiple routes can be selected and only their own stops are shown" do
    another = @company.delivery_runs.create!(name: "Segunda ruta", scheduled_date: @company.local_date, driver: @driver, status: :assigned)
    get repartidor_root_path(run_id: another.id)
    assert_response :success
    assert_select "select[name=run_id] option", count: 2
    assert_select ".delivery-item", count: 0
  end

  test "record delivery with actual quantities and complete the run while preserving merchandise" do
    patch repartidor_visit_path(@visit), params: completed_params.merge(visit: completed_params[:visit].merge(company_id: companies(:two).id, customer_id: customers(:other_company).id))
    assert_redirected_to repartidor_root_path(run_id: @run.id)
    assert @visit.reload.completed?
    assert @visit.completed_at
    assert_equal BigDecimal("2"), @item.reload.delivered_quantity
    assert_equal BigDecimal("3"), @item.planned_quantity
    assert_equal @company.id, @visit.company_id
    assert_equal customers(:one), @visit.customer
    assert @run.reload.completed?
    follow_redirect!
    assert_select "h3", text: "¡Recorrido finalizado!"
    assert_select ".activity-hero .amount", text: "1"
  end

  test "all quantities are required and an invalid later item rolls back earlier writes" do
    second = @visit.delivery_items.create!(description: "Aceite", unit: "l", planned_quantity: 2)
    [ [], [ { id: @item.id, delivered_quantity: 2 } ], [ { id: @item.id, delivered_quantity: 2 }, { id: second.id, delivered_quantity: "-1" } ],
      [ { id: @item.id, delivered_quantity: "1.5" }, { id: second.id, delivered_quantity: 0 } ],
      [ { id: @item.id, delivered_quantity: "" }, { id: second.id, delivered_quantity: 0 } ] ].each do |items|
      patch repartidor_visit_path(@visit), params: { visit: { status: "completed", items: items } }
      assert_response :unprocessable_entity
      assert @visit.reload.pending?
      assert_nil @item.reload.delivered_quantity
      assert_nil second.reload.delivered_quantity
      assert @run.reload.assigned?
    end
  end

  test "incidents require a reason and resolve the visit with zero delivered" do
    patch repartidor_visit_path(@visit), params: { visit: { status: "not_attended", notes: "" } }
    assert_response :unprocessable_entity
    @visit.update!(notes: "Tocar timbre")
    patch repartidor_visit_path(@visit), params: { visit: { status: "not_attended", notes: "Cliente ausente" } }
    assert_redirected_to repartidor_root_path(run_id: @run.id)
    assert @visit.reload.not_attended?
    assert_equal "Tocar timbre\nCliente ausente", @visit.notes
    assert_equal 0, @item.reload.delivered_quantity
    assert @run.reload.completed?
  end

  test "resolving one stop starts the run and preserves pending stops" do
    @run.visits.create!(company: @company, customer: customers(:one), position: 2)
    patch repartidor_visit_path(@visit), params: completed_params
    assert_redirected_to repartidor_root_path(run_id: @run.id)
    assert @run.reload.in_progress?
  end

  test "duplicate submission and changed quantities cannot overwrite a finalized visit" do
    patch repartidor_visit_path(@visit), params: completed_params
    patch repartidor_visit_path(@visit), params: { visit: { status: "completed", items: [ { id: @item.id, delivered_quantity: 1 } ] } }
    assert_response :conflict
    assert_equal 2, @item.reload.delivered_quantity
  end

  test "other drivers and tenants cannot update visits and forged item ids are rejected" do
    [ users(:other_driver), @company.users.create!(name: "Colega", email_address: "colleague@example.test", role: :driver, password: "Password-test-2026") ].each do |user|
      sign_in_as user
      patch repartidor_visit_path(@visit), params: completed_params
      assert_response :not_found
    end
    sign_in_as @driver
    patch repartidor_visit_path(@visit), params: { visit: { status: "completed", items: [ { id: @item.id + 999, delivered_quantity: 2 } ] } }
    assert_response :unprocessable_entity
    assert @visit.reload.pending?
    assert_nil @item.reload.delivered_quantity
  end

  test "reassignment prevents stale pages from recording delivery" do
    @run.update!(driver: nil, status: :draft)
    patch repartidor_visit_path(@visit), params: completed_params
    assert_response :not_found
    assert @visit.reload.pending?
  end

  test "manifest and service worker are public and scoped to the driver area" do
    sign_out
    get repartidor_manifest_path
    assert_response :success
    manifest = response.parsed_body
    manifest = JSON.parse(response.body) unless manifest.is_a?(Hash)
    assert_equal "/repartidor", manifest["start_url"]
    assert_equal "/repartidor", manifest["scope"]
    assert_equal [ "192x192", "512x512" ], manifest["icons"].map { |icon| icon["sizes"] }
    get repartidor_service_worker_path
    assert_response :success
    assert_equal "/repartidor", response.headers["Service-Worker-Allowed"]
    assert_includes response.body, 'event.request.method !== "GET"'
  end

  test "unpublished and past routes cannot record visits from a stale screen" do
    @run.update!(status: :draft)
    patch repartidor_visit_path(@visit), params: completed_params
    assert_response :conflict
    assert @visit.reload.pending?
    @run.update!(status: :assigned)
    travel_to 1.day.from_now do
      patch repartidor_visit_path(@visit), params: completed_params
      assert_response :conflict
    end
    assert_nil @item.reload.delivered_quantity
  end

  test "validation errors keep the submitted quantities and notes" do
    patch repartidor_visit_path(@visit), params: { visit: { status: "completed", notes: "Recibió María", items: [ { id: @item.id, delivered_quantity: "1.5" } ] } }
    assert_response :unprocessable_entity
    assert_select "#quantity-#{@item.id}[value='1.5']"
    assert_select "#visit-#{@visit.id} textarea", text: "Recibió María"
    assert_nil @item.reload.delivered_quantity
  end

  test "order backed visits complete the order and keep item traceability" do
    order = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @company.local_date,
      delivery_order_items_attributes: [ { description: "Pedido del cliente", unit: "box", quantity: 2 } ])
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ order.id ])
    visit = order.reload.visit
    item = visit.delivery_items.first
    patch repartidor_visit_path(visit), params: { visit: { status: "completed", items: [ { id: item.id, delivered_quantity: 1 } ] } }
    assert_redirected_to repartidor_root_path(run_id: @run.id)
    assert order.reload.needs_attention?
    assert visit.reload.completed?
    assert_equal 1, item.reload.delivered_quantity
    assert_equal order.delivery_order_items.first.id, item.delivery_order_item_id
    assert @run.reload.in_progress?
  end

  test "activity supports Rails named time zones" do
    @company.update!(time_zone: "Buenos Aires")
    patch repartidor_visit_path(@visit), params: completed_params
    follow_redirect!
    assert_response :success
    assert_select ".activity-hero .amount", text: "1"
  end

  test "ten visits keep their actual authors and quantities after a mid route reassignment" do
    pedro = @company.users.create!(name: "Pedro", email_address: "pedro@example.test", role: :driver, password: "Password-test-2026")
    @visit.update!(customer_name: "Parada 1")
    stops = [ @visit ] + 9.times.map do |index|
      stop = @run.visits.create!(customer: customers(:one), position: index + 2, customer_name: "Parada #{index + 2}")
      stop.delivery_items.create!(description: "Bultos", unit: "box", planned_quantity: 3)
      stop
    end
    stops.first(5).each { |stop| confirm_stop(stop) }
    snapshots = stops.first(5).map { |stop| [ stop.reload.attributes, stop.delivery_items.first.reload.attributes ] }
    assert @run.reload.in_progress?

    sign_in_as users(:one)
    patch delivery_run_path(@run), params: { delivery_run: { driver_id: pedro.id } }
    assert_redirected_to delivery_run_path(@run)
    assert_equal pedro, @run.reload.driver

    sign_in_as @driver
    get repartidor_root_path
    assert_select ".history-row small", text: /Parada/, count: 5
    assert_select ".activity-hero .amount", text: "5"
    patch repartidor_visit_path(stops.last), params: { visit: { status: "closed", notes: "Intento desde pantalla vieja" } }
    assert_response :not_found

    sign_in_as pedro
    stops.last(5).each { |stop| confirm_stop(stop) }
    assert @run.reload.completed?
    get repartidor_root_path
    assert_select ".history-row small", count: 5
    assert_select ".activity-hero .amount", text: "5"
    assert_select ".history-row small", text: "Parada 1", count: 0
    assert_equal [ @driver.id ], stops.first(5).map { |stop| stop.reload.confirmed_by_id }.uniq
    assert_equal [ pedro.id ], stops.last(5).map { |stop| stop.reload.confirmed_by_id }.uniq
    assert_equal snapshots, stops.first(5).map { |stop| [ stop.reload.attributes, stop.delivery_items.first.reload.attributes ] }
  end

  test "history excludes unknown legacy authors and confirmations performed by administration" do
    legacy = @run.visits.create!(customer: customers(:one), customer_name: "Sin autor histórico", position: 2)
    legacy.update_columns(status: "completed", completed_at: Time.current)
    sign_in_as users(:supervisor)
    patch delivery_run_visit_path(@run, @visit), params: { visit: { status: "completed", confirmed_by_id: @driver.id, confirmed_at: 2.days.ago,
      delivery_items_attributes: [ { id: @item.id, delivered_quantity: 3 } ] } }
    assert_redirected_to delivery_run_path(@run)
    assert_equal users(:supervisor), @visit.reload.confirmed_by
    assert_in_delta Time.current, @visit.confirmed_at, 5
    assert @run.reload.completed?
    assert_nil legacy.reload.confirmed_by_id
    assert_nil legacy.confirmed_at
    get delivery_run_path(@run)
    assert_select ".hint", text: /Autoría desconocida/
    assert_select ".hint", text: /Ana Supervisor/
    sign_in_as @driver
    get repartidor_root_path
    assert_select ".history-row", count: 0
    assert_select ".activity-hero .amount", text: "0"
  end

  private

  def confirm_stop(stop)
    patch repartidor_visit_path(stop), params: { visit: { status: "completed", items: [ { id: stop.delivery_items.first.id, delivered_quantity: 2 } ] } }
    assert_redirected_to repartidor_root_path(run_id: @run.id)
  end

  def completed_params
    { visit: { status: "completed", notes: "Recibió el encargado", items: [ { id: @item.id, delivered_quantity: 2 } ] } }
  end
end
