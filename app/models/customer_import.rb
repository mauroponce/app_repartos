class CustomerImport < ApplicationRecord
  include TenantIntegrity
  validate :bounded_payload

  def expired?
    created_at && created_at < 24.hours.ago
  end

  private

  def bounded_payload
    errors.add(:rows, "supera el límite permitido") if rows.size > CustomerImportReader.max_rows
    columns = mapping.values.reject(&:blank?)
    unless mapping.keys.all? { |field| CustomerImporter::FIELDS.include?(field) } && columns.uniq.size == columns.size && columns.all? { |index| index.to_s.match?(/\A\d+\z/) && index.to_i < headers.size }
      errors.add(:mapping, "requiere columnas válidas sin repetir")
    end
    unless excluded_rows.all? { |number| number.is_a?(Integer) && number.between?(2, rows.size + 1) }
      errors.add(:excluded_rows, "contiene filas inválidas")
    end
  end
end
