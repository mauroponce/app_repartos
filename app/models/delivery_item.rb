class DeliveryItem < ApplicationRecord
  attr_accessor :copying_schedule_snapshot
  include TenantIntegrity
  include MerchandiseSnapshot
  belongs_to :visit, inverse_of: :delivery_items
  belongs_to :delivery_order_item, optional: true
  before_validation -> { self.company ||= visit&.company || visit&.delivery_run&.company }
  validates :planned_quantity, merchandise_quantity: true
  validates :delivered_quantity, merchandise_quantity: { zero: true, allow_nil: true }
  validate -> { same_company(:visit); same_company(:delivery_order_item) }
  validate :protect_execution
  before_destroy :allow_destruction

  def protect_execution
    planning_fields = %w[product_id description unit planned_quantity]
    if visit&.persisted? && !visit.delivery_run.editable? && (new_record? || (changes_to_save.keys & planning_fields).any?)
      errors.add(:base, "La hoja ya no admite cambios en la mercadería planificada")
    end
    if delivery_order_item && delivery_order_item.delivery_order.visit_id != visit_id
      errors.add(:delivery_order_item, "debe pertenecer a una entrega de esta visita")
    end
    if visit&.persisted? && (visit.status_in_database != "pending" || visit.delivery_run.status.in?(%w[completed cancelled])) && (new_record? || has_changes_to_save?)
      errors.add(:base, "La visita finalizada conserva sus cantidades")
    end
    if persisted? && delivered_quantity_in_database && (changes_to_save.keys - %w[delivered_quantity notes updated_at]).any?
      errors.add(:base, "No se puede cambiar mercadería con cantidades registradas")
    end
    if delivery_order_item && persisted? && (changes_to_save.keys & %w[visit_id delivery_order_item_id]).any?
      errors.add(:base, "No se puede cambiar la trazabilidad")
    end
  end

  def allow_destruction
    return if visit&.plannable? && !visit.delivery_run.status.in?(%w[completed cancelled])
    errors.add(:base, "La visita ya tiene ejecución registrada")
    throw :abort
  end

  def difference
    delivered_quantity - planned_quantity unless delivered_quantity.nil? || planned_quantity.nil?
  end
end
