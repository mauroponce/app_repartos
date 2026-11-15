class NotificationEvent < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  STATUSES = { "requested" => "Solicitud registrada", "accepted" => "Aceptada por el proveedor", "delivered" => "Entrega confirmada por el proveedor", "failed" => "Envío fallido", "suppressed" => "Envío omitido" }.freeze
  belongs_to :customer_notification
  validates :event_key, :occurred_at, presence: true
  validates :event_key, :provider, :provider_message_id, :error_code, length: { maximum: 255 }
  validates :status, inclusion: { in: STATUSES.keys }
  validates :event_key, uniqueness: { scope: :company_id }
  validates :provider, presence: true, if: -> { status.in?(%w[accepted delivered failed]) }
  validate -> { same_company(:customer_notification) }
end
