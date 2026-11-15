require "test_helper"
require "socket"

class VroomClientTest < ActiveSupport::TestCase
  test "posts the JSON contract and parses a valid response" do
    with_endpoint('{"code":0,"routes":[],"unassigned":[]}') do |requests|
      assert_equal 0, VroomClient.new.call({ jobs: [], vehicles: [] })["code"]
      assert_equal({ "jobs" => [], "vehicles" => [] }, JSON.parse(requests.pop))
    end
  end

  test "handles upstream HTTP routing and malformed response failures" do
    [ [ "unavailable", 503 ], [ "<html>error</html>", 200 ], [ '{"code":3,"error":"private upstream detail"}', 200 ], [ "{}", 200 ] ].each do |body, status|
      with_endpoint(body, status: status) do
        error = assert_raises(VroomClient::Error) { VroomClient.new.call({}) }
        assert_not_includes error.message, "private upstream detail"
      end
    end
  end

  test "fails clearly without configuration or on a refused connection" do
    original = ENV["VROOM_URL"]
    ENV.delete("VROOM_URL")
    assert_match(/VROOM_URL/, assert_raises(VroomClient::Error) { VroomClient.new.call({}) }.message)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    ENV["VROOM_URL"] = "http://127.0.0.1:#{port}"
    assert_match(/conectar/, assert_raises(VroomClient::Error) { VroomClient.new.call({}) }.message)
    ENV["VROOM_URL"] = "file:///tmp/optimizer"
    assert_raises(VroomClient::Error) { VroomClient.new.call({}) }
  ensure
    ENV["VROOM_URL"] = original
  end

  private

  def with_endpoint(body, status: 200)
    original = ENV["VROOM_URL"]
    server = TCPServer.new("127.0.0.1", 0)
    ENV["VROOM_URL"] = "http://127.0.0.1:#{server.addr[1]}"
    requests = Queue.new
    thread = Thread.new do
      socket = server.accept
      headers = +""
      headers << socket.read(1) until headers.end_with?("\r\n\r\n")
      length = headers[/Content-Length: (\d+)/i, 1].to_i
      requests << socket.read(length)
      socket.write("HTTP/1.1 #{status} Test\r\nContent-Length: #{body.bytesize}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end
    yield requests
  ensure
    thread&.kill
    thread&.join
    server&.close
    ENV["VROOM_URL"] = original
  end
end
