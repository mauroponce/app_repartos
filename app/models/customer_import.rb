class CustomerImport < ApplicationRecord
  include TenantIntegrity
  belongs_to :initiated_by, class_name: "User", optional: true
  has_one_attached :source_file
  has_many :import_rows, class_name: "CustomerImportRow", dependent: :delete_all
  validate :bounded_payload
  validate -> { same_company(:initiated_by) }

  def intelligent?
    state != "legacy"
  end

  def editable?
    state == "review" && !expired?
  end

  def working?
    state.in?(%w[reading preparing processing importing])
  end

  def progress
    total_rows.positive? ? (processed_rows * 100 / total_rows).clamp(0, 100) : 0
  end


  def expired?
    created_at && created_at < 24.hours.ago
  end

  private

  def bounded_payload
    errors.add(:rows, "supera el límite permitido") if rows.size > CustomerImportReader.max_rows
    columns = mapping.values.reject(&:blank?)
    unless mapping.keys.all? { |field| (CustomerImporter::FIELDS + %w[district province postal_code country]).include?(field) } && columns.uniq.size == columns.size && columns.all? { |index| index.to_s.match?(/\A\d+\z/) && index.to_i < headers.size }
      errors.add(:mapping, "requiere columnas válidas sin repetir")
    end
    unless excluded_rows.all? { |number| number.is_a?(Integer) && number.between?(2, rows.size + 1) }
      errors.add(:excluded_rows, "contiene filas inválidas")
    end
  end
end
