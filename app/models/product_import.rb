class ProductImport < ApplicationRecord
  include TenantIntegrity
  validate :bounded_payload

  def expired?
    created_at && created_at < 24.hours.ago
  end

  private

  def bounded_payload
    errors.add(:rows, "supera el límite permitido") if rows.size > ProductImportReader::MAX_ROWS
  end
end
