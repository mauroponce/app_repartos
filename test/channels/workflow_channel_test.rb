require "test_helper"

class WorkflowChannelTest < ActionCable::Channel::TestCase
  test "only managers subscribe to their own tenant administration stream" do
    signed = Turbo::StreamsChannel.signed_stream_name([ companies(:one), :workflow_admin ])
    stub_connection current_user: users(:one)
    subscribe signed_stream_name: signed
    assert subscription.confirmed?
    assert_has_stream Turbo::StreamsChannel.verified_stream_name(signed)
    stub_connection current_user: users(:driver)
    subscribe signed_stream_name: signed
    assert subscription.rejected?
    stub_connection current_user: users(:two)
    subscribe signed_stream_name: signed
    assert subscription.rejected?
  end

  test "driver streams are private to both the user and company even with another signed identifier" do
    signed = Turbo::StreamsChannel.signed_stream_name([ companies(:one), "user_#{users(:driver).id}", :workflow_driver ])
    stub_connection current_user: users(:driver)
    subscribe signed_stream_name: signed
    assert subscription.confirmed?
    stub_connection current_user: users(:other_driver)
    subscribe signed_stream_name: signed
    assert subscription.rejected?
    stub_connection current_user: users(:supervisor)
    subscribe signed_stream_name: signed
    assert subscription.rejected?
  end
end
