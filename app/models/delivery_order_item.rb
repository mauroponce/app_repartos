class DeliveryOrderItem < ApplicationRecord
  attr_accessor :copying_schedule_snapshot
  include TenantIntegrity
  after_commit -> { OpportunityRefreshRequest.call(company_id) }, on: %i[create update destroy]
  include MerchandiseSnapshot
  include CommercialSnapshot
  belongs_to :delivery_order, inverse_of: :delivery_order_items
  has_one :delivery_item, dependent: :restrict_with_error
  before_validation -> { self.company ||= delivery_order&.company }
  validates :quantity, merchandise_quantity: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate -> { same_company(:delivery_order) }
  validate :protect_execution
  before_destroy :allow_destruction

  def remaining_quantity
    delivered = delivery_item&.delivered_quantity
    [ quantity - delivered, 0.to_d ].max unless delivered.nil?
  end

  private

  def protect_execution
    if delivery_order&.persisted? && !delivery_order.editable? && (new_record? || has_changes_to_save? || marked_for_destruction?)
      errors.add(:base, "La entrega ya no admite cambios en su mercadería")
    end
  end

  def allow_destruction
    return if delivery_order.editable?
    errors.add(:base, "La entrega ya no admite cambios en su mercadería")
    throw :abort
  end
end
