module MerchandiseSnapshot
  extend ActiveSupport::Concern

  included do
    belongs_to :product, optional: true
    before_validation :fill_product_snapshot
    validates :description, presence: true, length: { maximum: 255 }
    validates :unit, inclusion: { in: DeliveryUnits::CODES }
    validate :product_integrity
  end

  private

  def fill_product_snapshot
    return unless product && (new_record? || will_save_change_to_product_id?)
    self.description = product.name if description.blank?
    self.unit = product.unit if unit.blank?
  end

  def product_integrity
    same_company(:product)
    return unless product && (new_record? || will_save_change_to_product_id? || will_save_change_to_unit?)
    # Generated delivery items may copy an older unit or an inactive product.
    return if respond_to?(:copying_schedule_snapshot) && copying_schedule_snapshot
    errors.add(:product, "está inactivo; elegí otro producto o un ítem manual") unless product.active?
    errors.add(:unit, "debe coincidir con la del producto seleccionado") unless unit == product.unit
  end
end
