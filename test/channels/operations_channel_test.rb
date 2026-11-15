require "test_helper"

class OperationsChannelTest < ActionCable::Channel::TestCase
  test "only active managers can subscribe to their company invalidations" do
    company = companies(:one)
    signed = Turbo::StreamsChannel.signed_stream_name([ company, :operations ])
    stub_connection current_user: users(:one)
    subscribe signed_stream_name: signed
    assert subscription.confirmed?
    assert_has_stream Turbo::StreamsChannel.verified_stream_name(signed)
  end

  test "driver and foreign company subscription are rejected" do
    signed = Turbo::StreamsChannel.signed_stream_name([ companies(:one), :operations ])
    stub_connection current_user: users(:driver)
    subscribe signed_stream_name: signed
    assert subscription.rejected?
    stub_connection current_user: users(:two)
    subscribe signed_stream_name: signed
    assert subscription.rejected?
  end
end
