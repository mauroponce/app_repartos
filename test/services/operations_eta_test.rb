require "test_helper"
require "socket"

class OperationsEtaTest < ActiveSupport::TestCase
  setup do
    @company = companies(:one)
    @date = @company.local_date
    @now = ActiveSupport::TimeZone[@company.time_zone].local(@date.year, @date.month, @date.day, 9)
    @run = @company.delivery_runs.new(name: "ETA", scheduled_date: @date, driver: users(:driver), status: :assigned)
    @orders = 2.times.map do |index|
      @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @date, window_start: "#{10 + index}:00", window_end: "#{10 + index}:30", service_minutes: 15,
        delivery_order_items_attributes: [ { description: "Pan", quantity: 10, unit: "pack" } ])
    end
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: @orders.map(&:id))
  end

  def location
    users(:driver).update!(location_sharing_enabled: true, location_consent_id: SecureRandom.uuid, location_activated_at: Time.current)
    @company.driver_locations.create!(user: users(:driver), latitude: -34.79, longitude: -58.33, accuracy: 10, captured_at: Time.current)
  end

  test "OSRM route legs respect stop order waiting and unloading and refresh dashboard" do
    travel_to @now do
      point = location
      with_endpoint({ code: "Ok", routes: [ { legs: [ { duration: 600 }, { duration: 3600 } ] } ] }.to_json) do |requests|
        OperationsEtaJob.perform_now(@company.id, point.user_id)
        path = requests.pop
        assert_includes path, "/route/v1/driving/-58.33,-34.79;"
        assert_includes path, "overview=false"
        data = point.reload.eta_data
        assert_equal @run.id, data["run_id"]
        assert_equal @run.visits.pluck(:id), data["stops"].pluck("visit_id")
        assert_equal "10:00", Time.iso8601(data["stops"][0]["arrival_at"]).in_time_zone(@company.time_zone).strftime("%H:%M")
        assert_equal "11:15", Time.iso8601(data["stops"][1]["arrival_at"]).in_time_zone(@company.time_zone).strftime("%H:%M")
        snapshot = OperationsSnapshot.new(company: @company)
        assert_equal 2, snapshot.estimates(snapshot.runs.first).size
        @orders.last.update!(notes: "Cambió la planificación")
        snapshot = OperationsSnapshot.new(company: @company)
        assert_empty snapshot.estimates(snapshot.runs.first)
      end
    end
  end

  test "missing router stale position missing geocode and changed address show no estimate" do
    travel_to @now do
      point = location
      original = ENV.delete("OSRM_URL")
      assert_empty OperationsEta.call(run: @run, location: point)
      ENV["OSRM_URL"] = "http://127.0.0.1:1"
      point.captured_at = 3.minutes.ago
      assert_empty OperationsEta.call(run: @run, location: point)
      point.captured_at = Time.current
      customers(:one).update!(latitude: nil, longitude: nil)
      @run.reload
      assert_empty OperationsEta.call(run: @run, location: point)
    ensure
      ENV["OSRM_URL"] = original
    end
  end

  test "a route changed while OSRM responds cannot save an obsolete estimate" do
    travel_to @now do
      point = location
      original = ENV["OSRM_URL"]
      ENV["OSRM_URL"] = "http://configured.example.test"
      singleton = OperationsEta.singleton_class
      original_call = OperationsEta.method(:call)
      changed_order = @orders.first
      singleton.define_method(:call) do |**_args|
        changed_order.update!(notes: "Nueva instrucción durante el cálculo")
        { run_id: -1, stops: [] }
      end
      OperationsEtaJob.perform_now(@company.id, point.user_id)
      assert_empty point.reload.eta_data
    ensure
      singleton&.define_method(:call, original_call) if original_call
      ENV["OSRM_URL"] = original
    end
  end

  test "routing failures and malformed durations never become guessed ETAs" do
    travel_to @now do
      point = location
      [ [ "unavailable", 503 ], [ "bad json", 200 ], [ { code: "Ok", routes: [ { legs: [ { duration: -1 }, { duration: 1 } ] } ] }.to_json, 200 ] ].each do |body, status|
        with_endpoint(body, status: status) do
          assert_raises(OperationsEta::Unavailable) { OperationsEta.call(run: @run, location: point) }
        end
      end
    end
  end

  private

  def with_endpoint(body, status: 200)
    original = ENV["OSRM_URL"]
    server = TCPServer.new("127.0.0.1", 0)
    ENV["OSRM_URL"] = "http://127.0.0.1:#{server.addr[1]}"
    requests = Queue.new
    thread = Thread.new do
      socket = server.accept
      headers = +""
      headers << socket.read(1) until headers.end_with?("\r\n\r\n")
      requests << headers.lines.first
      socket.write("HTTP/1.1 #{status} Test\r\nContent-Length: #{body.bytesize}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end
    yield requests
  ensure
    thread&.kill
    thread&.join
    server&.close
    ENV["OSRM_URL"] = original
  end
end
