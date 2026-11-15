class CustomerNotification < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  belongs_to :customer
  belongs_to :delivery_order, optional: true
  belongs_to :user, optional: true
  has_many :notification_events, -> { order(:id) }, dependent: :restrict_with_error
  validates :channel, inclusion: { in: CommunicationConsent::CHANNELS.keys }
  validates :purpose, inclusion: { in: CommunicationConsent::PURPOSES.keys }
  validates :template_key, :operation_id, presence: true
  validates :template_key, :recipient, length: { maximum: 255 }
  validates :operation_id, uniqueness: { scope: :company_id }
  validate :tenant_links

  def status
    statuses = notification_events.reorder(:id).pluck(:status)
    %w[delivered failed accepted suppressed requested].find { |value| statuses.include?(value) } || "requested"
  end

  def dispatchable?
    customer.reload.active? && recipient.present? && recipient == self.class.recipient_for(customer, channel) &&
      CommunicationConsent.allowed?(customer: customer, channel: channel, purpose: purpose) && status == "requested"
  end

  def self.recipient_for(customer, channel)
    return "" unless customer
    (channel == "email" ? customer.email : customer.phone).to_s
  end

  private

  def tenant_links
    [ :customer, :delivery_order, :user ].each { |name| same_company(name) }
    if delivery_order && delivery_order.customer_id != customer_id
      errors.add(:delivery_order, "debe corresponder al cliente")
    end
  end
end
