class Product < ApplicationRecord
  include TenantIntegrity
  has_many :delivery_schedule_items, dependent: :restrict_with_error
  has_many :delivery_items, dependent: :restrict_with_error

  normalizes :sku, :package_content_unit, with: ->(value) { value.strip.presence }
  normalizes :name, with: ->(value) { value.strip }
  validates :name, presence: true, length: { maximum: 255 }
  validates :sku, uniqueness: { scope: :company_id }, allow_nil: true, length: { maximum: 255 }
  validates :unit, inclusion: { in: DeliveryUnits::CODES }
  validates :active, inclusion: { in: [ true, false ] }
  validates :package_content_unit, inclusion: { in: DeliveryUnits::CODES }, allow_nil: true
  validates :package_content_quantity, merchandise_quantity: { unit: :package_content_unit, allow_nil: true }
  validate :complete_package

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(Arel.sql("LOWER(products.name)"), :id) }
  scope :search, ->(query) {
    where("products.name ILIKE :q OR products.sku ILIKE :q", q: "%#{sanitize_sql_like(query)}%")
  }

  private

  def complete_package
    if package_content_quantity.present? != package_content_unit.present?
      errors.add(:package_content_quantity, "requiere cantidad y unidad de contenido juntas")
    end
  end
end
