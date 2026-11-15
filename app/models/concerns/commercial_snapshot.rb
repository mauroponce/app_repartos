module CommercialSnapshot
  extend ActiveSupport::Concern
  FIELDS = %w[unit_price unit_cost currency commercial_captured_at commercial_source].freeze
  included do
    attr_accessor :preserve_commercial_snapshot
    before_validation :capture_commercial_values
    validates :unit_price, :unit_cost, monetary_value: { allow_nil: true }
    validates :currency, inclusion: { in: %w[ARS USD EUR] }, allow_nil: true
    validates :commercial_source, inclusion: { in: %w[catalog manual order legacy] }, allow_nil: true
    validate :complete_commercial_values
  end

  private

  def commercial_company
    company || (is_a?(DeliveryOrderItem) ? delivery_order&.company : visit&.company)
  end

  def capture_commercial_values
    # Failed cross-tenant submissions must not populate a rendered error form
    # with another company's commercial values.
    return if product && product.company_id != commercial_company&.id
    return if is_a?(DeliveryItem) && delivery_order_item && delivery_order_item.company_id != commercial_company&.id
    if is_a?(DeliveryItem) && delivery_order_item
      if new_record? || preserve_commercial_snapshot
        assign_attributes(delivery_order_item.attributes.slice(*FIELDS))
        self.commercial_source = "order" if unit_price || unit_cost
      end
      return
    end
    if persisted? && will_save_change_to_product_id? && product && !preserve_commercial_snapshot
      self.unit_price = product.unit_price unless will_save_change_to_unit_price?
      self.unit_cost = product.unit_cost unless will_save_change_to_unit_cost?
    end
    if new_record?
      unless preserve_commercial_snapshot
        catalog_values = product && (unit_price.nil? || unit_price == product.unit_price) && (unit_cost.nil? || unit_cost == product.unit_cost)
        self.unit_price = product&.unit_price if unit_price.nil?
        self.unit_cost = product&.unit_cost if unit_cost.nil?
        self.currency ||= commercial_company&.currency
        self.commercial_source ||= catalog_values ? "catalog" : "manual"
        self.commercial_captured_at ||= Time.current
      end
    elsif will_save_change_to_unit_price? || will_save_change_to_unit_cost?
      self.commercial_source = will_save_change_to_product_id? && product && unit_price == product.unit_price && unit_cost == product.unit_cost ? "catalog" : "manual"
      self.commercial_captured_at = Time.current
      self.currency ||= commercial_company&.currency
    end
  end

  def complete_commercial_values
    if is_a?(DeliveryItem) && delivery_order_item && persisted? && !preserve_commercial_snapshot && (changes_to_save.keys & FIELDS).any?
      errors.add(:base, "Los precios y costos se modifican desde el pedido mientras admite edición")
    end
    if (unit_price || unit_cost) && (currency.blank? || commercial_captured_at.nil? || commercial_source.blank?)
      errors.add(:base, "Los valores comerciales requieren moneda, fecha y origen")
    end
    if persisted? && will_save_change_to_currency? && (unit_price_in_database || unit_cost_in_database)
      errors.add(:currency, "no se puede cambiar en un valor histórico")
    end
  end
end
