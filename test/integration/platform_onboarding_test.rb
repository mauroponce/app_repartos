require "test_helper"

class PlatformOnboardingTest < ActionDispatch::IntegrationTest
  setup do
    @admin = PlatformAdmin.create!(name: "Propietario", email_address: "owner@platform.test", password: "Platform-test-2026")
  end

  test "platform login is isolated, creates company and principal, and logout revokes access" do
    post platform_session_path, params: { email_address: @admin.email_address, password: "Platform-test-2026" }
    assert_redirected_to platform_root_path
    assert_equal 1, @admin.platform_sessions.count
    get admin_root_path
    assert_redirected_to new_session_path
    assert_difference [ "Company.count", "User.count" ], 1 do
      post platform_companies_path, params: registration
    end
    company = Company.find_by!(slug: "onboarding-test")
    assert_equal "America/Argentina/Buenos_Aires", company.time_zone
    assert_equal "ARS", company.currency
    assert_equal "Buenos Aires", company.province
    assert_equal company, company.primary_administrator.company
    assert company.primary_administrator.administrator?
    assert_equal "owner@new-company.test", company.primary_administrator.email_address
    follow_redirect!
    assert_select "h1", "Empresa de prueba"
    assert_no_match "Company-test-2026", response.body
    delete platform_session_path
    assert_equal 0, @admin.platform_sessions.count
    get platform_root_path
    assert_redirected_to new_platform_session_path
    post session_path, params: { email_address: company.primary_administrator.email_address, password: "Company-test-2026" }
    assert_redirected_to admin_root_url
  end

  test "failed principal creation rolls back company and rejects duplicate slug email and weak password" do
    login
    [ { administrator_email: users(:one).email_address }, { slug: companies(:one).slug }, { password: "weak" }, { administrator_email: "invalid" }, { time_zone: "Invalid/Zone" } ].each do |changes|
      assert_no_difference [ "Company.count", "User.count" ] do
        post platform_companies_path, params: { registration: registration[:registration].merge(changes) }
      end
      assert_response :unprocessable_entity
    end
  end

  test "operational sessions cannot authorize platform and both logouts leave the other identity intact" do
    sign_in_as users(:one)
    get platform_root_path
    assert_redirected_to new_platform_session_path
    post platform_session_path, params: { email_address: users(:one).email_address, password: "password" }
    assert_redirected_to new_platform_session_path
    login
    delete platform_session_path
    get admin_root_path
    assert_response :success
    login
    delete session_path
    get platform_root_path
    assert_response :success
    @admin.platform_sessions.update_all(expires_at: 1.minute.ago)
    get platform_root_path
    assert_redirected_to new_platform_session_path
    sign_in_as users(:driver)
    get platform_root_path
    assert_redirected_to new_platform_session_path
  end

  test "platform session is revoked by a password change and login is rate limited" do
    login
    @admin.update!(password: "Changed-password-2026")
    get platform_root_path
    assert_redirected_to new_platform_session_path
    store = ActiveSupport::Cache::MemoryStore.new
    cache = Platform::SessionsController.cache_store
    original = cache.method(:increment)
    cache.define_singleton_method(:increment) { |*args, **options| store.increment(*args, **options) }
    11.times { post platform_session_path, params: { email_address: @admin.email_address, password: "incorrect" } }
    assert_match "Demasiados intentos", flash[:alert]
  ensure
    cache&.define_singleton_method(:increment, original) if original
  end

  private

  def login
    post platform_session_path, params: { email_address: @admin.email_address, password: "Platform-test-2026" }
  end

  def registration
    { registration: { name: "Empresa de prueba", slug: "onboarding-test", administrator_name: "Administradora",
      administrator_email: "OWNER@NEW-COMPANY.TEST", password: "Company-test-2026",
      company_id: companies(:two).id, role: "platform_admin" } }
  end
end
