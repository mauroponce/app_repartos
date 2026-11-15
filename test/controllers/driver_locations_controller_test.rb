require "test_helper"

class DriverLocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = companies(:one)
    @driver = users(:driver)
    @run = @company.delivery_runs.create!(name: "Ubicación", scheduled_date: @company.local_date, driver: @driver, status: :assigned)
    @consent_id = SecureRandom.uuid
    sign_in_as @driver
  end

  def send_location(**attributes)
    post "/repartidor/api/v1/location", params: { location: {
      latitude: -34.8, longitude: -58.3, accuracy: 15, captured_at: Time.current.iso8601, command: "sample",
      consent_id: @consent_id, expected_version: @driver.reload.location_consent_version,
      account: "#{@company.id}:#{@driver.id}" }.merge(attributes) }, as: :json
  end

  def activate
    send_location(command: "activate")
    assert_response :success
    assert @driver.reload.location_sharing_enabled?
  end

  test "sharing is off by default and permission or coordinates alone cannot activate it" do
    get "/repartidor/api/v1/location"
    assert_response :success
    assert_equal false, response.parsed_body["sharing"]
    send_location
    assert_response :conflict
    assert_empty @company.driver_locations
    assert_not @driver.reload.location_sharing_enabled?
  end

  test "voluntary activation stores only newest position and revocation deletes it and rejects delayed samples" do
    activate
    send_location
    assert_response :success
    location = @company.driver_locations.find_by!(user: @driver)
    assert location.fresh?
    assert_equal "no-store", response.headers["Cache-Control"]
    send_location(latitude: -35, captured_at: 1.minute.ago.iso8601)
    assert_response :success
    assert_equal(-34.8, location.reload.latitude.to_f)
    assert_equal 1, @company.driver_locations.count
    previous_version = @driver.reload.location_consent_version
    send_location(command: "deactivate")
    assert_response :success
    assert_not @driver.reload.location_sharing_enabled?
    assert @driver.location_activated_at
    assert @driver.location_deactivated_at
    assert_empty @company.driver_locations
    send_location(expected_version: previous_version)
    assert_response :conflict
    send_location(command: "activate", expected_version: previous_version)
    assert_response :conflict
    assert_empty @company.driver_locations
  end

  test "a stop arriving before activation prevents that delayed activation and duplicate stops are idempotent" do
    send_location(command: "deactivate")
    assert_response :success
    version = @driver.reload.location_consent_version
    send_location(command: "deactivate")
    assert_equal version, @driver.reload.location_consent_version
    send_location(command: "activate", expected_version: 0)
    assert_response :conflict
    @consent_id = SecureRandom.uuid
    activate
  end

  test "bounds freshness and active assignment are required and foreign actors cannot choose a driver" do
    activate
    send_location(account: "999:999")
    assert_response :forbidden
    [ { latitude: 91 }, { captured_at: 6.minutes.ago.iso8601 }, { captured_at: 3.minutes.from_now.iso8601 }, { accuracy: -1 } ].each do |attributes|
      send_location(**attributes)
      assert_response :unprocessable_entity
    end
    assert_empty @company.driver_locations
    @run.update!(driver: nil, status: :draft)
    send_location
    assert_response :unprocessable_entity
    send_location(command: "deactivate")
    assert_response :success
    sign_in_as users(:one)
    send_location
    assert_response :forbidden
    sign_in_as users(:other_driver)
    send_location
    assert_response :forbidden
  end

  test "session revocation disables sharing and stale samples never appear current and are purged" do
    activate
    send_location
    location = @company.driver_locations.find_by!(user: @driver)
    travel 3.minutes do
      assert_not location.fresh?
    end
    travel 25.hours do
      DriverLocationRetentionJob.perform_now
      assert_not DriverLocation.exists?(location.id)
    end
    @driver.sessions.destroy_all
    assert_not @driver.reload.location_sharing_enabled?
    send_location
    assert_response :unauthorized
  end
end
