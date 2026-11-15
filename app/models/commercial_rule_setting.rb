class CommercialRuleSetting < ApplicationRecord
  include TenantIntegrity
  belongs_to :auto_assignee, class_name: "User", optional: true
  validates :company_id, uniqueness: true
  validates :inactivity_min_days, :comparison_days, :partial_grace_days, :cooldown_days, numericality: { only_integer: true, in: 1..365 }
  validates :decline_min_orders, :shortage_min_orders, :failure_min_orders, numericality: { only_integer: true, in: 1..1000 }
  validates :decline_percent, numericality: { only_integer: true, in: 1..100 }
  validates :inactivity_multiplier, numericality: { in: 1..10 }
  validate do
    same_company(:auto_assignee)
    errors.add(:automatic_rules, "contiene reglas desconocidas") unless (automatic_rules - CommercialOpportunity::RULES.keys).empty?
    if automatic_rules.any? && (!auto_assignee || !auto_assignee.active? || !auto_assignee.manages_customers?)
      errors.add(:auto_assignee, "elegí un administrador o supervisor activo")
    end
  end
end
