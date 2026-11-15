class CustomerImportRow < ApplicationRecord
  include TenantIntegrity
  belongs_to :customer_import
  belongs_to :customer, optional: true
  validate -> { same_company(:customer_import); same_company(:customer) }
  validates :precision, inclusion: { in: %w[reliable approximate ambiguous unlocated] }
  validates :review_state, inclusion: { in: %w[pending automatic manual unlocated] }
  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true
  validate do
    errors.add(:base, "Completá ambas coordenadas") if latitude.nil? != longitude.nil?
    errors.add(:base, "Confirmá un punto válido") if manual_confirmation && (latitude.nil? || review_state != "manual")
  end

  PRECISION_LABELS = { "reliable" => "Ubicación confiable", "approximate" => "Ubicación aproximada", "ambiguous" => "Ubicación ambigua", "unlocated" => "Sin ubicación" }.freeze

  def verified?
    review_state.in?(%w[automatic manual]) && latitude.present? && longitude.present?
  end

  def label
    manual_confirmation? ? "Confirmada manualmente" : PRECISION_LABELS.fetch(precision)
  end
end
