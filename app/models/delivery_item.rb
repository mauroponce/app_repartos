class DeliveryItem < ApplicationRecord
  attr_accessor :copying_schedule_snapshot
  include TenantIntegrity
  include MerchandiseSnapshot
  belongs_to :visit, inverse_of: :delivery_items
  before_validation -> { self.company ||= visit&.company || visit&.delivery_run&.company }
  validates :planned_quantity, merchandise_quantity: true
  validates :delivered_quantity, merchandise_quantity: { zero: true, allow_nil: true }
  validate -> { same_company(:visit) }

  def difference
    delivered_quantity - planned_quantity unless delivered_quantity.nil? || planned_quantity.nil?
  end
end
