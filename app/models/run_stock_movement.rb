class RunStockMovement < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  KINDS = { "load" => "Carga", "delivery" => "Entrega", "return" => "Devolución al depósito", "waste" => "Merma", "adjustment_in" => "Ajuste de entrada", "adjustment_out" => "Ajuste de salida" }.freeze
  belongs_to :delivery_run
  belongs_to :user, optional: true
  belongs_to :product, optional: true
  belongs_to :delivery_item, optional: true
  validates :kind, inclusion: { in: KINDS.keys }
  validates :description, presence: true, length: { maximum: 255 }
  validates :reason, length: { maximum: 500 }
  validates :unit, inclusion: { in: DeliveryUnits::CODES }
  validates :quantity, merchandise_quantity: true
  validates :operation_id, :occurred_at, presence: true
  validates :operation_id, uniqueness: { scope: :company_id }
  validate :valid_movement

  private

  def valid_movement
    [ :delivery_run, :user, :product, :delivery_item ].each { |name| same_company(name) }
    if kind == "delivery"
      unless delivery_item && delivery_item.visit.delivery_run_id == delivery_run_id && !delivery_item.visit.pending? && delivery_item.delivered_quantity == quantity && unit == delivery_item.unit && product_id == delivery_item.product_id
        errors.add(:delivery_item, "debe reflejar una entrega real de esta hoja")
      end
    elsif delivery_item_id
      errors.add(:delivery_item, "solo corresponde a movimientos de entrega")
    end
    errors.add(:reason, "es obligatorio para ajustes y mermas") if kind.in?(%w[waste adjustment_in adjustment_out]) && reason.blank?
  end
end
