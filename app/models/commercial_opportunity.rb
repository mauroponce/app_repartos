class CommercialOpportunity < ApplicationRecord
  include TenantIntegrity
  include WorkflowUpdates
  RULES = { "inactive" => "Cliente sin pedidos recientes", "decline" => "Disminución de pedidos", "shortage" => "Faltantes recurrentes de producto", "repeated_failure" => "Entregas fallidas reiteradas", "unfollowed_partial" => "Entrega parcial sin seguimiento" }.freeze
  STATUSES = { "open" => "Abierta", "managed" => "Gestionada", "snoozed" => "Pospuesta", "dismissed" => "Descartada", "cleared" => "Condición superada" }.freeze
  belongs_to :customer, optional: true
  belongs_to :product, optional: true
  belongs_to :delivery_order, optional: true
  has_many :workflow_tasks, dependent: :restrict_with_error
  has_many :workflow_events, dependent: :restrict_with_error
  validates :rule, inclusion: { in: RULES.keys }
  validates :status, inclusion: { in: STATUSES.keys }
  validates :title, :stable_key, :fingerprint, :detected_at, :last_evaluated_at, :state_changed_at, presence: true
  validates :stable_key, uniqueness: { scope: :company_id }
  validates :title, length: { maximum: 255 }
  validates :resolution, length: { maximum: 4000 }
  validate -> { same_company(:customer); same_company(:product); same_company(:delivery_order) }
  before_destroy { errors.add(:base, "Las oportunidades conservan su historial"); throw :abort }
end
