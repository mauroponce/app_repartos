require "test_helper"

class DriverLocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = companies(:one)
    @run = @company.delivery_runs.create!(name: "Ubicación", scheduled_date: @company.local_date, driver: users(:driver), status: :assigned)
    sign_in_as users(:driver)
  end

  def send_location(**attributes)
    post "/repartidor/api/v1/location", params: { location: {
      latitude: -34.8, longitude: -58.3, accuracy: 15, captured_at: Time.current.iso8601, sharing: true,
      account: "#{Current.company.id}:#{Current.user.id}" }.merge(attributes) }, as: :json
  end

  test "stores only newest position of authenticated driver and supports stopping" do
    send_location
    assert_response :success
    location = @company.driver_locations.find_by!(user: users(:driver))
    assert location.fresh?
    assert_equal "no-store", response.headers["Cache-Control"]
    send_location(latitude: -35, captured_at: 1.minute.ago.iso8601)
    assert_response :success
    assert_equal(-34.8, location.reload.latitude.to_f)
    assert_equal 1, @company.driver_locations.count
    send_location(sharing: false)
    assert_response :success
    assert_not location.reload.sharing?
    assert_not location.fresh?
    assert_empty location.eta_data
    # A delayed sample captured before the explicit stop must not restart it.
    send_location(captured_at: 1.second.ago.iso8601)
    assert_response :success
    assert_not location.reload.sharing?
    travel 25.hours do
      DriverLocationRetentionJob.perform_now
      assert_not DriverLocation.exists?(location.id)
    end
  end

  test "bounds freshness and active assignment required and foreign actor cannot choose driver" do
    send_location(account: "999:999")
    assert_response :forbidden
    send_location(latitude: 91)
    assert_response :unprocessable_entity
    send_location(captured_at: 6.minutes.ago.iso8601)
    assert_response :unprocessable_entity
    send_location(captured_at: 3.minutes.from_now.iso8601)
    assert_response :unprocessable_entity
    send_location(accuracy: -1)
    assert_response :unprocessable_entity
    assert_empty @company.driver_locations
    @run.update!(driver: nil, status: :draft)
    send_location
    assert_response :unprocessable_entity
    sign_in_as users(:one)
    send_location
    assert_response :forbidden
    sign_in_as users(:other_driver)
    send_location
    assert_response :unprocessable_entity
  end
end
