class CommunicationConsent < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  CHANNELS = { "email" => "Email", "sms" => "SMS", "whatsapp" => "WhatsApp" }.freeze
  PURPOSES = { "operational" => "Avisos de entregas", "marketing" => "Comunicaciones comerciales" }.freeze
  belongs_to :customer
  belongs_to :user
  before_validation -> { self.recipient = CustomerNotification.recipient_for(customer, channel) }, on: :create
  validates :recipient, presence: true, if: -> { decision == "granted" }
  validates :channel, inclusion: { in: CHANNELS.keys }
  validates :purpose, inclusion: { in: PURPOSES.keys }
  validates :decision, inclusion: { in: %w[granted revoked] }
  validates :evidence, presence: true, length: { maximum: 500 }
  validates :occurred_at, presence: true
  validate -> { same_company(:customer); same_company(:user) }

  def self.allowed?(customer:, channel:, purpose:)
    consent = where(company_id: customer.company_id, customer_id: customer.id, channel: channel, purpose: purpose).order(id: :desc).first
    consent&.decision == "granted" && consent.recipient.present? && consent.recipient == CustomerNotification.recipient_for(customer, channel)
  end
end
