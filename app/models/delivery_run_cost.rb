class DeliveryRunCost < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  CATEGORIES = { "vehicle" => "Uso del vehículo", "fuel" => "Combustible", "toll" => "Peajes", "driver" => "Repartidor", "other" => "Otro costo de ruta" }.freeze
  belongs_to :delivery_run
  belongs_to :user
  belongs_to :reversal_of, class_name: "DeliveryRunCost", optional: true
  has_one :reversal, class_name: "DeliveryRunCost", foreign_key: :reversal_of_id
  validates :category, inclusion: { in: CATEGORIES.keys }
  validates :description, presence: true, length: { maximum: 255 }
  validates :vehicle_label, length: { maximum: 255 }
  validates :amount, monetary_value: { signed: true }
  validates :currency, inclusion: { in: %w[ARS USD EUR] }
  validates :incurred_at, :operation_id, presence: true
  validates :operation_id, uniqueness: { scope: :company_id }
  validate :valid_cost

  private

  def valid_cost
    [ :delivery_run, :user, :reversal_of ].each { |name| same_company(name) }
    errors.add(:base, "Los costos de la hoja ya están cerrados") if new_record? && delivery_run&.costs_closed_at
    errors.add(:currency, "debe coincidir con la hoja") if delivery_run && currency != delivery_run.currency
    if reversal_of
      unless reversal_of.delivery_run_id == delivery_run_id && reversal_of.reversal_of_id.nil? && amount == -reversal_of.amount && currency == reversal_of.currency && estimated == reversal_of.estimated
        errors.add(:reversal_of, "no corresponde a una anulación completa de este costo")
      end
    elsif amount && amount.negative?
      errors.add(:amount, "requiere un costo original para anular")
    end
  end
end
