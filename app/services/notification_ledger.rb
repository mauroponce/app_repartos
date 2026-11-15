class NotificationLedger
  def self.request(company:, customer_id:, channel:, purpose:, template_key:, operation_id:, order_id: nil, user: nil)
    company.with_lock do
      customer = company.customers.find(customer_id)
      order = company.delivery_orders.find(order_id) if order_id.present?
      recipient = CustomerNotification.recipient_for(customer, channel)
      values = { customer: customer, delivery_order: order, user: user, channel: channel, purpose: purpose,
        template_key: template_key, operation_id: operation_id, recipient: recipient }
      if (existing = company.customer_notifications.find_by(operation_id: operation_id))
        probe = company.customer_notifications.new(values)
        fields = %w[customer_id delivery_order_id user_id channel purpose template_key]
        raise ArgumentError, "El identificador ya corresponde a otra notificación" unless fields.all? { |key| existing[key] == probe[key] }
        return existing
      end
      notification = company.customer_notifications.create!(values)
      code = if !customer.active?
        "customer_inactive"
      elsif recipient.blank?
        "recipient_missing"
      elsif !CommunicationConsent.allowed?(customer: customer, channel: channel, purpose: purpose)
        "consent_missing"
      end
      notification.notification_events.create!(company: company, event_key: "request:#{operation_id}",
        status: code ? "suppressed" : "requested", error_code: code, occurred_at: Time.current)
      notification
    end
  end

  def self.record(company:, notification_id:, event_key:, status:, occurred_at:, provider: nil, provider_message_id: nil, error_code: nil)
    company.with_lock do
      notification = company.customer_notifications.find(notification_id)
      values = { customer_notification: notification, event_key: event_key, status: status, occurred_at: occurred_at,
        provider: provider, provider_message_id: provider_message_id, error_code: error_code }
      if (existing = company.notification_events.find_by(event_key: event_key))
        probe = company.notification_events.new(values)
        fields = %w[customer_notification_id status occurred_at provider provider_message_id error_code]
        raise ArgumentError, "El evento ya corresponde a otro resultado" unless fields.all? { |key| existing[key] == probe[key] }
        return existing
      end
      company.notification_events.create!(values)
    end
  end
end
