require "test_helper"

class OsrmClientTest < ActiveSupport::TestCase
  POINTS = [ [ -58.38, -34.60 ], [ -58.40, -34.61 ] ].freeze
  def table_body
    { code: "Ok", durations: [ [ 0, 31 ], [ 70, 0 ] ], distances: [ [ 0, 400 ], [ 900, 0 ] ] }
  end

  def route_body
    { code: "Ok", routes: [ { distance: 400, duration: 31, geometry: { type: "LineString", coordinates: POINTS }, legs: [ { distance: 400, duration: 31 } ] } ] }
  end

  def client(body = table_body, code: 200, &block)
    Osrm::Client.new(url: "http://osrm:5000", transport: block || ->(_uri) { Struct.new(:code, :body).new(code.to_s, body.is_a?(String) ? body : body.to_json) }, sleeper: ->(_) { })
  end

  test "table preserves seconds metres and asymmetric arcs" do
    result = client.table(POINTS)
    assert_equal [ [ 0, 31 ], [ 70, 0 ] ], result[:durations]
    assert_equal [ [ 0, 400 ], [ 900, 0 ] ], result[:distances]
  end

  test "coordinates are longitude latitude and one matrix request covers every pair" do
    requests = []
    c = client { |uri| requests << uri; Struct.new(:code, :body).new("200", table_body.to_json) }
    c.table(POINTS)
    assert_equal 1, requests.size
    assert_includes requests.first.path, "-58.38,-34.6;-58.4,-34.61"
    assert_includes requests.first.query, "annotations=duration%2Cdistance"
    assert_not_includes requests.first.query, "fallback_speed"
  end

  test "unreachable null arcs remain unknown and never become straight line distances" do
    body = table_body.merge(durations: [ [ 0, nil ], [ 70, 0 ] ], distances: [ [ 0, nil ], [ 900, 0 ] ])
    assert_nil client(body).table(POINTS)[:durations][0][1]
  end

  test "a partially null connection is invalid" do
    assert_raises(Osrm::Client::InvalidResponse) { client(table_body.merge(distances: [ [ 0, nil ], [ 900, 0 ] ])).table(POINTS) }
  end

  test "incomplete matrix dimensions are rejected" do
    assert_raises(Osrm::Client::InvalidResponse) { client(table_body.merge(durations: [ [ 0 ] ])).table(POINTS) }
  end

  test "negative durations and distances are rejected" do
    %i[durations distances].each do |key|
      assert_raises(Osrm::Client::InvalidResponse) { client(table_body.merge(key => [ [ 0, -1 ], [ 1, 0 ] ])).table(POINTS) }
    end
  end

  test "invalid JSON and non object bodies are rejected" do
    [ "{broken", "[]", "null" ].each { |body| assert_raises(Osrm::Client::InvalidResponse) { client(body).table(POINTS) } }
  end

  test "missing OSRM success code is rejected" do
    assert_raises(Osrm::Client::InvalidResponse) { client({ durations: [] }).table(POINTS) }
  end

  test "http errors are not accepted as routes" do
    assert_raises(Osrm::Client::InvalidResponse) { client({}, code: 403).table(POINTS) }
  end

  test "transient HTTP failures retry at most once against the same host" do
    calls = []
    c = client { |uri| calls << uri.host; Struct.new(:code, :body).new("503", "unavailable") }
    assert_raises(Osrm::Client::Unavailable) { c.table(POINTS) }
    assert_equal %w[osrm osrm], calls
  end

  test "open timeout retries are bounded" do
    calls = 0
    c = client { |_uri| calls += 1; raise Net::OpenTimeout }
    assert_raises(Osrm::Client::Unavailable) { c.table(POINTS) }
    assert_equal 2, calls
  end

  test "read timeout retries are bounded" do
    calls = 0
    c = client { |_uri| calls += 1; raise Net::ReadTimeout }
    assert_raises(Osrm::Client::Unavailable) { c.table(POINTS) }
    assert_equal 2, calls
  end

  test "connection refused never falls back to a public provider" do
    hosts = []
    c = client { |uri| hosts << uri.host; raise Errno::ECONNREFUSED }
    assert_raises(Osrm::Client::Unavailable) { c.table(POINTS) }
    assert_equal [ "osrm" ], hosts.uniq
  end

  test "coordinates invalid ranges strings and non finite values are rejected before HTTP" do
    [ [], [ [ 181, 0 ], POINTS.first ], [ [ 0, -91 ], POINTS.first ], [ [ "-58", -34 ], POINTS.first ], [ [ Float::INFINITY, 0 ], POINTS.first ], [ [ 0 ], POINTS.first ] ].each do |points|
      assert_raises(Osrm::Client::Error) { client { flunk "Should not call OSRM" }.table(points) }
    end
  end

  test "coordinate limit is enforced" do
    assert_raises(Osrm::Client::Error) { client.table(Array.new(102) { POINTS.first }) }
  end

  test "a hundred stops can include both depot endpoints in the route request" do
    points = Array.new(102) { POINTS.first }
    body = route_body
    body[:routes].first[:legs] = Array.new(101) { { distance: 0, duration: 0 } }
    assert_equal 101, client(body).route(points).fetch("legs").size
    assert_raises(Osrm::Client::Error) { client(body).route(points + [ POINTS.first ]) }
  end

  test "route includes GeoJSON and per leg road metrics" do
    result = client(route_body).route(POINTS)
    assert_equal 400, result["distance"]
    assert_equal 31, result["duration"]
    assert_equal "LineString", result.dig("geometry", "type")
    assert_equal 400, result["legs"].first["distance"]
  end

  test "no route is explicit" do
    assert_raises(Osrm::Client::NoRoute) { client({ code: "NoRoute" }).route(POINTS) }
    assert_raises(Osrm::Client::NoRoute) { client({ code: "NoSegment" }, code: 400).table(POINTS) }
  end

  test "route without matching legs or geometry cannot be displayed as valid" do
    body = route_body
    body[:routes].first[:legs] = []
    assert_raises(Osrm::Client::InvalidResponse) { client(body).route(POINTS) }
    body = route_body
    body[:routes].first[:geometry][:coordinates] = [ [ 999, 0 ], [ 0, 0 ] ]
    assert_raises(Osrm::Client::InvalidResponse) { client(body).route(POINTS) }
  end

  test "redirects cannot redirect requests to arbitrary destinations" do
    assert_raises(Osrm::Client::InvalidResponse) { client({}, code: 302).table(POINTS) }
  end

  test "provider config is server controlled and disallows URL credentials and paths" do
    [ "", "file:///etc/passwd", "http://secret:password@osrm:5000", "http://osrm/api", "http://osrm?redirect=evil" ].each do |url|
      assert_raises(Osrm::Client::Unavailable) { Osrm::Client.new(url: url) }
    end
  end

  test "oversized responses and external fallback cells are rejected" do
    assert_raises(Osrm::Client::InvalidResponse) { client(" " * (Osrm::Client::MAX_BYTES + 1)).table(POINTS) }
    assert_raises(Osrm::Client::InvalidResponse) { client(table_body.merge(fallback_speed_cells: [ [ 0, 1 ] ])).table(POINTS) }
  end

  test "a retry may recover and return the real matrix" do
    attempts = 0
    c = client do |_uri|
      attempts += 1
      raise Net::ReadTimeout if attempts == 1
      Struct.new(:code, :body).new("200", table_body.to_json)
    end
    assert_equal 31, c.table(POINTS)[:durations][0][1]
    assert_equal 2, attempts
  end
end
