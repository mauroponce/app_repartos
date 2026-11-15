require "test_helper"

class CommunicationLedgerTest < ActiveSupport::TestCase
  setup do
    @company = companies(:one)
    @customer = customers(:one)
    @user = users(:one)
  end

  def consent(decision = "granted", **extra)
    @customer.communication_consents.create!({ company: @company, user: @user, channel: "email", purpose: "operational", decision: decision,
      evidence: "Autorización del receptor por email", occurred_at: Time.current }.merge(extra))
  end

  def request_notice(id: SecureRandom.uuid, **extra)
    NotificationLedger.request(company: @company, customer_id: @customer.id, user: @user, operation_id: id,
      channel: "email", purpose: "operational", template_key: "delivery_update", **extra)
  end

  test "a contact does not grant consent and purposes and changed recipients are independent" do
    suppressed = request_notice
    assert_equal "suppressed", suppressed.status
    assert_equal "consent_missing", suppressed.notification_events.sole.error_code
    consent
    assert CommunicationConsent.allowed?(customer: @customer, channel: "email", purpose: "operational")
    assert_not CommunicationConsent.allowed?(customer: @customer, channel: "email", purpose: "marketing")
    notice = request_notice
    assert notice.dispatchable?
    assert_equal "requested", notice.status
    @customer.update!(email: "different@example.test")
    assert_not notice.dispatchable?
    assert_not CommunicationConsent.allowed?(customer: @customer, channel: "email", purpose: "operational")
    assert_equal "pedidos@almacen.test", notice.recipient
    consent
    assert request_notice.dispatchable?
    consent("revoked")
    assert_equal "suppressed", request_notice.status
  end

  test "provider events are immutable idempotent and delivery cannot be downgraded by late acceptance" do
    consent
    id = SecureRandom.uuid
    notice = request_notice(id: id)
    assert_equal notice, request_notice(id: id)
    time = Time.current.change(usec: 0)
    values = { company: @company, notification_id: notice.id, event_key: "provider:123:delivery", status: "delivered", occurred_at: time,
      provider: "test-provider", provider_message_id: "123" }
    event = NotificationLedger.record(**values)
    assert_equal event, NotificationLedger.record(**values)
    assert_raises(ArgumentError) { NotificationLedger.record(**values.merge(status: "failed")) }
    NotificationLedger.record(**values.merge(event_key: "provider:123:acceptance", status: "accepted", occurred_at: time - 1.minute))
    assert_equal "delivered", notice.reload.status
    assert_not event.update(status: "failed")
    consent("revoked")
    # Historical provider facts remain recordable after revocation; a revoked
    # preference must prevent a new dispatch, not erase what already happened.
    NotificationLedger.record(**values.merge(event_key: "provider:123:late-confirmation"))
    assert_equal "delivered", notice.reload.status
    assert_not notice.dispatchable?
  end

  test "cross tenant associations and changing consent history are rejected" do
    record = consent
    assert_not record.update(decision: "revoked")
    assert_not record.destroy
    assert_raises(ActiveRecord::RecordNotFound) { NotificationLedger.request(company: @company, customer_id: customers(:other_company).id, channel: "email", purpose: "operational", template_key: "x", operation_id: SecureRandom.uuid) }
    assert_raises(ActiveRecord::RecordInvalid) { consent(user: users(:two)) }
  end
end
