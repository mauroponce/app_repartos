class DeliveryScheduleItem < ApplicationRecord
  include TenantIntegrity
  include MerchandiseSnapshot
  belongs_to :delivery_schedule, inverse_of: :delivery_schedule_items
  before_validation -> { self.company ||= delivery_schedule&.company }
  validates :quantity, merchandise_quantity: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate -> { same_company(:delivery_schedule) }
end
