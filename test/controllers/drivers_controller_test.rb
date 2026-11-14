require "test_helper"

class DriversControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "directory only shows drivers from the current company and real counters" do
    get drivers_path
    assert_response :success
    assert_select ".driver-row", count: 2
    assert_select ".customer-name", text: users(:one).name, count: 0
    assert_select ".customer-name", text: users(:other_driver).name, count: 0
    assert_select ".kpi-value", text: "2", count: 1
    assert_select "a[href=?].nav-link.active", drivers_path
    assert_select "a[href=?]", new_driver_path
  end

  test "search by name email phone and escaped wildcards combines with status" do
    [ "Juan", "DRIVER@", "9876" ].each do |query|
      get drivers_path, params: { q: query, status: "active" }
      assert_select ".driver-row", count: 1
      assert_select ".customer-name", text: users(:driver).name
    end
    get drivers_path, params: { status: "inactive" }
    assert_select ".driver-row", count: 1
    assert_select ".customer-name", text: users(:inactive_driver).name
    get drivers_path, params: { q: "%" }
    assert_select ".driver-row", count: 0
    assert_select "h2", text: "No encontramos repartidores"
    get drivers_path, params: { status: "invalid" }
    assert_select ".driver-row", count: 2
  end

  test "directory has alphabetic pagination and preserves filters" do
    13.times do |index|
      companies(:one).users.create!(name: "Equipo #{index.to_s.rjust(2, '0')}", role: :driver, email_address: "equipo-#{index}@example.test", password: "Repartos-test-2026")
    end
    get drivers_path, params: { q: "Equipo", status: "active" }
    assert_select ".driver-row", count: 12
    assert_select ".customer-name" do |links|
      assert_equal (0...12).map { |index| "Equipo #{index.to_s.rjust(2, '0')}" }, links.map(&:text)
    end
    assert_select "a[href=?]", drivers_path(q: "Equipo", status: "active", page: 2)
    get drivers_path, params: { q: "Equipo", status: "active", page: 999 }
    assert_select ".driver-row", count: 1
    assert_select ".customer-name", text: "Equipo 12"
  end

  test "autocomplete stays within tenant role and status and does not expose credentials" do
    get autocomplete_drivers_path, params: { q: "Juan", status: "active" }
    assert_response :success
    assert_equal [ { "name" => "Juan Repartidor", "contact" => "driver@example.test", "city" => "+54 11 5555-9876" } ], response.parsed_body
    assert_includes response.headers["Cache-Control"], "no-store"
    [ "ajeno", "Lucía", "" ].each do |query|
      get autocomplete_drivers_path, params: { q: query }
      assert_equal [], response.parsed_body
    end
  end

  test "create fixes tenant and role and new driver is available for delivery assignment" do
    get new_driver_path, headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "form[action=?]", drivers_path
    assert_select "input[name='driver[password]'][required]"
    assert_difference "User.count" do
      post drivers_path, params: { driver: valid_attributes.merge(company_id: companies(:two).id, role: "administrator") }
    end
    assert_redirected_to drivers_path
    driver = User.find_by!(email_address: valid_attributes[:email_address])
    assert driver.driver?
    assert_equal companies(:one), driver.company
    assert driver.authenticate(valid_attributes[:password])
    get new_delivery_run_path
    assert_select "select[name='delivery_run[driver_id]'] option[value=?]", driver.id
    assert_select "select[name='delivery_run[driver_id]'] option[value=?]", users(:inactive_driver).id, count: 0
  end

  test "invalid creation returns errors and keeps safe input values" do
    [ { name: " " }, { email_address: "invalid" }, { email_address: users(:one).email_address.upcase }, { password: "short" }, { password_confirmation: "Different-password" }, { status: "invalid" } ].each do |invalid|
      assert_no_difference "User.count" do
        post drivers_path, params: { driver: valid_attributes.merge(invalid) }
      end
      assert_response :unprocessable_entity
      assert_select "turbo-frame#modal"
      assert_select "[role=alert]"
      assert_select "input[name='driver[password]'][value]", count: 0
    end
  end

  test "show and edit use modal and blank password preserves credentials" do
    driver = users(:driver)
    get driver_path(driver)
    assert_response :success
    assert_select "dialog[data-modal-return-url-value=?]", drivers_path
    assert_select "h1", text: driver.name
    get edit_driver_path(driver)
    assert_response :success
    digest = driver.password_digest
    patch driver_path(driver), params: { driver: { name: "Juan Actualizado", phone: "12345", password: "", password_confirmation: "", role: "administrator", company_id: companies(:two).id } }
    assert_redirected_to driver_path(driver)
    assert_equal "Juan Actualizado", driver.reload.name
    assert_equal digest, driver.password_digest
    assert driver.driver?
    assert_equal companies(:one), driver.company
    patch driver_path(driver), params: { driver: { name: "" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]"
    assert_equal "Juan Actualizado", driver.reload.name
  end

  test "password change revokes existing sessions" do
    driver = users(:driver)
    driver.sessions.create!
    patch driver_path(driver), params: { driver: { password: "New-password-2026", password_confirmation: "New-password-2026" } }
    assert_redirected_to driver_path(driver)
    assert driver.reload.authenticate("New-password-2026")
    assert_empty driver.sessions
  end

  test "deactivation revokes sessions preserves history and reactivation restores availability" do
    driver = users(:driver)
    run = companies(:one).delivery_runs.create!(driver: driver, name: "Histórico", scheduled_date: "2026-11-17", status: :assigned)
    driver.sessions.create!
    patch driver_path(driver), params: { driver: { status: "inactive" } }
    assert_redirected_to driver_path(driver)
    assert driver.reload.inactive?
    assert_empty driver.sessions
    assert_equal driver, run.reload.driver
    get driver_path(driver)
    assert_select "a[href=?]", delivery_run_path(run)
    get edit_delivery_run_path(run)
    assert_select "select[name='delivery_run[driver_id]'] option[value=?]", driver.id
    patch delivery_run_path(run), params: { delivery_run: { name: "Histórico editado", driver_id: driver.id } }
    assert_redirected_to delivery_run_path(run)
    post delivery_runs_path, params: { delivery_run: { name: "Nuevo", scheduled_date: "2026-11-18", driver_id: driver.id } }
    assert_response :not_found
    patch driver_path(driver), params: { driver: { status: "active" } }
    assert driver.reload.active?
    get new_delivery_run_path
    assert_select "select[name='delivery_run[driver_id]'] option[value=?]", driver.id
  end

  test "delete removes unassigned driver and sessions but protects delivery history" do
    driver = users(:driver)
    driver.sessions.create!
    assert_difference "User.count", -1 do
      delete driver_path(driver)
    end
    assert_redirected_to drivers_path
    assert_empty Session.where(user_id: driver.id)
    driver = users(:inactive_driver)
    driver.update!(status: :active)
    run = companies(:one).delivery_runs.create!(driver: driver, name: "Histórico", scheduled_date: "2026-11-17")
    assert_no_difference [ "User.count", "DeliveryRun.count" ] do
      delete driver_path(driver)
    end
    assert_redirected_to driver_path(driver)
    assert_match "repartos asociados", flash[:alert]
    assert_equal driver, run.reload.driver
  end

  test "other tenants administrators and supervisors cannot be addressed as drivers" do
    [ users(:other_driver), users(:one), users(:supervisor) ].each do |user|
      [ driver_path(user), edit_driver_path(user) ].each do |path|
        get path
        assert_response :not_found
      end
      patch driver_path(user), params: { driver: { name: "Robado" } }
      assert_response :not_found
      delete driver_path(user)
      assert_response :not_found
    end
  end

  test "supervisors can manage while drivers are forbidden and guests redirected" do
    sign_in_as users(:supervisor)
    get drivers_path
    assert_response :success
    sign_in_as users(:driver)
    [ drivers_path, autocomplete_drivers_path, new_driver_path, driver_path(users(:inactive_driver)), edit_driver_path(users(:inactive_driver)) ].each do |path|
      get path
      assert_response :forbidden
    end
    assert_no_difference "User.count" do
      post drivers_path, params: { driver: valid_attributes }
      assert_response :forbidden
      patch driver_path(users(:inactive_driver)), params: { driver: { status: "active" } }
      assert_response :forbidden
      delete driver_path(users(:inactive_driver))
      assert_response :forbidden
    end
    sign_out
    get drivers_path
    assert_redirected_to new_session_path
  end

  private

  def valid_attributes
    { name: "María Nueva", email_address: "new-driver@example.test", phone: "+54 11 5555-0101", status: "active", password: "Repartos-test-2026", password_confirmation: "Repartos-test-2026" }
  end
end
