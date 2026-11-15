require "test_helper"

class CustomersControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "all customer endpoints require authentication" do
    sign_out
    [ customers_path, autocomplete_customers_path, new_customer_path, customer_path(customers(:one)), edit_customer_path(customers(:one)) ].each do |path|
      get path
      assert_redirected_to new_session_path
    end
    assert_no_difference "Customer.count" do
      post customers_path, params: { customer: valid_attributes }
    end
    assert_redirected_to new_session_path
    patch customer_path(customers(:one)), params: { customer: { name: "Sin permiso" } }
    assert_redirected_to new_session_path
    assert_not_equal "Sin permiso", customers(:one).reload.name
  end

  test "directory and metrics are scoped to the current company" do
    get customers_path
    assert_response :success
    assert_select ".customer-row", count: 2
    assert_select ".customer-name", text: customers(:one).name
    assert_select ".customer-name", text: customers(:other_company).name, count: 0
    assert_select ".kpi-value", text: "2", count: 2
  end

  test "another company sees only its own directory" do
    sign_in_as users(:two)
    get customers_path
    assert_select ".customer-row", count: 1
    assert_select ".customer-name", text: customers(:other_company).name
    assert_select ".customer-name", text: customers(:one).name, count: 0
  end

  test "search and status filters work together" do
    get customers_path, params: { q: "adroGUÉ", status: "active" }
    assert_response :success
    assert_select ".customer-row", count: 1
    assert_select ".customer-name", text: customers(:one).name
    get customers_path, params: { q: "Adrogué", status: "inactive" }
    assert_select ".customer-row", count: 0
    assert_select "h2", text: "No encontramos clientes"
  end

  test "wildcards in search are literal and cannot broaden the tenant scope" do
    get customers_path, params: { q: "%" }
    assert_response :success
    assert_select ".customer-row", count: 0
    get customers_path, params: { q: "' OR 1=1 --" }
    assert_response :success
    assert_select ".customer-row", count: 0
  end

  test "pagination bounds results and preserves filters" do
    13.times { |i| companies(:one).customers.create!(valid_attributes.merge(name: "Negocio #{i}")) }
    get customers_path, params: { q: "Negocio", status: "active" }
    assert_select ".customer-row", count: 12
    assert_select "a", text: "Siguiente →"
    get customers_path, params: { q: "Negocio", status: "active", page: 2 }
    assert_select ".customer-row", count: 1
    assert_select "a", text: "← Anterior"
  end

  test "table orders customers alphabetically in Spanish regardless of case" do
    customers(:one).update!(name: "zeta")
    customers(:inactive).update!(name: "alfa")
    companies(:one).customers.create!(valid_attributes.merge(name: "Beta"))
    companies(:one).customers.create!(valid_attributes.merge(name: "Álvaro"))
    companies(:one).customers.create!(valid_attributes.merge(name: "Ñandú"))
    get customers_path
    assert_select "table th[aria-sort=ascending]", text: "CLIENTE"
    assert_select ".customer-name" do |names|
      assert_equal [ "alfa", "Álvaro", "Beta", "Ñandú", "zeta" ], names.map(&:text)
    end
  end

  test "autocomplete is bounded alphabetical and scoped to the authenticated company" do
    10.times { |i| companies(:one).customers.create!(valid_attributes.merge(name: "Negocio #{9 - i}")) }
    companies(:two).customers.create!(valid_attributes.merge(name: "Negocio ajeno"))
    get autocomplete_customers_path, params: { q: "negoCIO", company_id: companies(:two).id }
    assert_response :success
    assert_equal (0..7).map { |i| "Negocio #{i}" }, response.parsed_body.map { |match| match.fetch("name") }
    assert_equal %w[city contact name], response.parsed_body.first.keys.sort
    assert_includes response.headers["Cache-Control"], "no-store"

    sign_in_as users(:two)
    get autocomplete_customers_path, params: { q: "Negocio" }
    assert_equal [ "Negocio ajeno" ], response.parsed_body.map { |match| match.fetch("name") }
  end

  test "autocomplete searches contact and city while respecting status and literal wildcards" do
    [ "María", "adroGUÉ" ].each do |query|
      get autocomplete_customers_path, params: { q: query, status: "active" }
      assert_equal [ customers(:one).name ], response.parsed_body.map { |match| match.fetch("name") }
    end
    get autocomplete_customers_path, params: { q: "Adrogué", status: "inactive" }
    assert_empty response.parsed_body
    [ "", "   ", "%", "' OR 1=1 --" ].each do |query|
      get autocomplete_customers_path, params: { q: query }
      assert_response :success
      assert_empty response.parsed_body
    end
  end

  test "new customer form is available as a Turbo frame" do
    get new_customer_path, headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "turbo-frame#modal dialog"
    assert_select "input[name='customer[company_id]']", count: 0
  end

  test "creates a customer in the authenticated company despite forged tenant attributes" do
    assert_difference "companies(:one).customers.count", 1 do
      assert_no_difference "companies(:two).customers.count" do
        post customers_path, params: { company_id: companies(:two).id, customer: valid_attributes.merge(company_id: companies(:two).id) }
      end
    end
    assert_redirected_to customers_path
    follow_redirect!
    assert_select ".flash", text: "Cliente creado correctamente."
    assert_select ".customer-name", text: "Nuevo Comercio"
  end

  test "invalid customer shows Spanish errors and preserves entered values" do
    assert_no_difference "Customer.count" do
      post customers_path, params: { customer: valid_attributes.merge(phone: "", email: "invalid") }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Email/
    assert_select "turbo-frame#modal", count: 1
    assert_select "input[name='customer[name]'][value='Nuevo Comercio']"
  end

  test "details cannot be read across companies even when requesting a Turbo frame" do
    get customer_path(customers(:other_company)), headers: { "Turbo-Frame" => "modal" }
    assert_response :not_found
    get customer_path(customers(:one)), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "h1", text: customers(:one).name
  end

  test "supervisors can manage customers" do
    sign_in_as users(:supervisor)
    get customers_path
    assert_response :success
    post customers_path, params: { customer: valid_attributes }
    assert_redirected_to customers_path
  end

  test "drivers cannot read or create customers in the admin panel" do
    sign_in_as users(:driver)
    [ customers_path, autocomplete_customers_path, new_customer_path, customer_path(customers(:one)), edit_customer_path(customers(:one)) ].each do |path|
      get path
      assert_response :forbidden
    end
    assert_no_difference "Customer.count" do
      post customers_path, params: { customer: valid_attributes }
    end
    assert_response :forbidden
    patch customer_path(customers(:one)), params: { customer: { name: "Sin permiso" } }
    assert_response :forbidden
    assert_not_equal "Sin permiso", customers(:one).reload.name
  end

  test "customer names are escaped" do
    customers(:one).update!(name: "<script>alert('x')</script>")
    get customers_path
    assert_select ".customer-row script", count: 0
    assert_includes response.body, "&lt;script&gt;"
  end

  test "requires a complete location when creating a customer" do
    assert_no_difference "Customer.count" do
      post customers_path, params: { customer: valid_attributes.except(:latitude, :longitude) }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Latitud/
    assert_select "[role=alert]", text: /Longitud/
  end

  test "persists geographic coordinates and displays the saved map" do
    post customers_path, params: { customer: valid_attributes }
    customer = companies(:one).customers.find_by!(name: "Nuevo Comercio")
    assert_equal BigDecimal("-34.8003128"), customer.latitude
    assert_equal BigDecimal("-58.3370290"), customer.longitude
    get customer_path(customer)
    assert_select "[data-location-readonly-value=true][data-location-latitude-value]"
    assert_select "a[href=?]", edit_customer_path(customer)
  end

  test "edit loads saved coordinates and update preserves the tenant" do
    customer = customers(:one)
    get edit_customer_path(customer), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "input[name='customer[latitude]'][value='-34.8003128']"
    assert_select "input[name='customer[company_id]']", count: 0
    patch customer_path(customer), params: { customer: { name: "Comercio editado", latitude: "-34.8012345", longitude: "-58.3412345", company_id: companies(:two).id } }
    assert_redirected_to customer_path(customer)
    assert_equal companies(:one), customer.reload.company
    assert_equal "Comercio editado", customer.name
    assert_equal BigDecimal("-34.8012345"), customer.latitude
    follow_redirect!
    assert_select ".flash", text: "Cliente actualizado correctamente."
  end

  test "cannot edit or update another company's customer" do
    customer = customers(:other_company)
    get edit_customer_path(customer), headers: { "Turbo-Frame" => "modal" }
    assert_response :not_found
    patch customer_path(customer), params: { customer: valid_attributes }
    assert_response :not_found
    assert_equal "Comercio Privado Norte", customer.reload.name
  end

  test "changed address requires a newly confirmed point" do
    customer = customers(:one)
    patch customer_path(customer), params: { customer: { address: "Otra calle 123" } }
    assert_response :unprocessable_entity
    assert_equal "San Martín 123", customer.reload.address
    patch customer_path(customer), params: { customer: { address: "Otra calle 123", latitude: customer.latitude, longitude: customer.longitude, location_confirmed: "true" } }
    assert_redirected_to customer_path(customer)
    assert_equal "Otra calle 123", customer.reload.address
    assert customer.located?
  end

  test "legacy customer must be located when edited" do
    customer = customers(:inactive)
    patch customer_path(customer), params: { customer: { contact: "Nuevo contacto" } }
    assert_response :unprocessable_entity
    patch customer_path(customer), params: { customer: { contact: "Nuevo contacto", latitude: "-34.75", longitude: "-58.39" } }
    assert_redirected_to customer_path(customer)
    assert customer.reload.located?
  end

  test "invalid coordinates are rejected and other entered values survive" do
    post customers_path, params: { customer: valid_attributes.merge(latitude: "91", longitude: "-181") }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Latitud/
    assert_select "input[name='customer[name]'][value='Nuevo Comercio']"
    patch customer_path(customers(:one)), params: { customer: { name: "", latitude: "-34.8123456", longitude: "-58.4123456" } }
    assert_response :unprocessable_entity
    assert_select "input[name='customer[latitude]'][value='-34.8123456']"
    assert_select "turbo-frame#modal", count: 1
  end

  private

  def valid_attributes
    { name: "Nuevo Comercio", contact: "Ana", phone: "+54 11 5555-1234", email: "hola@nuevo.test", address: "Mitre 100", city: "Adrogué", status: "active", latitude: "-34.8003128", longitude: "-58.3370290" }
  end
end
