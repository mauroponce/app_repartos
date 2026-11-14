require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "Repartos-test-2026" }

    assert_redirected_to root_path
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
end
