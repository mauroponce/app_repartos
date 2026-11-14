require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "Repartos-test-2026" }

    assert_redirected_to admin_root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "inactive users cannot sign in" do
    post session_path, params: { email_address: users(:inactive_driver).email_address, password: "Repartos-test-2026" }
    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "deactivation invalidates an already authenticated session" do
    sign_in_as users(:driver)
    users(:driver).update!(status: :inactive)
    get drivers_path
    assert_redirected_to new_session_path
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
    get customers_path
    assert_redirected_to new_session_path
  end

  test "forged session is rejected" do
    cookies[:session_id] = "forged"
    get customers_path
    assert_redirected_to new_session_path
  end

  test "login returns to the original page" do
    get new_customer_path
    assert_redirected_to new_session_path
    post session_path, params: { email_address: @user.email_address, password: "Repartos-test-2026" }
    assert_redirected_to new_customer_path
  end

  test "drivers sign in to their app even after requesting an admin page" do
    get new_customer_path
    post session_path, params: { email_address: users(:driver).email_address, password: "Repartos-test-2026" }
    assert_redirected_to repartidor_root_path
    get root_path
    assert_redirected_to repartidor_root_path
  end

  test "administrators and supervisors never return to the driver area after login" do
    [ users(:one), users(:supervisor) ].each do |user|
      sign_out
      get repartidor_root_path
      post session_path, params: { email_address: user.email_address, password: "Repartos-test-2026" }
      assert_redirected_to admin_root_path
    end
  end

  test "drivers can return to a requested route in their own area" do
    get repartidor_root_path(run_id: 123)
    post session_path, params: { email_address: users(:driver).email_address, password: "Repartos-test-2026" }
    assert_redirected_to repartidor_root_path(run_id: 123)
  end
end
