class DeliveryDispatchChange < ApplicationRecord
  include TenantIntegrity
  belongs_to :user
  belongs_to :delivery_order
  validates :reason, presence: true, length: { maximum: 500 }
  validate -> { same_company(:user); same_company(:delivery_order) }
  before_update { errors.add(:base, "El cambio conserva su auditoría"); throw :abort }
  before_destroy { errors.add(:base, "El cambio conserva su auditoría"); throw :abort }
end
