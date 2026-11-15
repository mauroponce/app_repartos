class DeliveryEvidence < ApplicationRecord
  include TenantIntegrity
  belongs_to :user
  belongs_to :driver_sync_operation, optional: true
  has_one_attached :file

  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  PHOTO_LIMIT = 2.megabytes
  SIGNATURE_LIMIT = 512.kilobytes
  MAX_PHOTOS = 4
  class MissingUpload < StandardError; end

  validates :kind, inclusion: { in: %w[photo signature] }
  validates :operation_id, :evidence_uuid, format: { with: UUID }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :visit_id, presence: true
  validate :valid_ownership
  validate :immutable_evidence, on: :update

  def self.resolve_manifest!(user:, operation_id:, visit_id:, manifest:)
    rows = Array(manifest).map { |row| row.to_h.stringify_keys.slice("id", "kind", "sha256") }
    rows.each { |row| row["id"] = row["id"].to_s.downcase }
    unless rows.size <= MAX_PHOTOS + 1 && rows.count { |row| row["kind"] == "photo" } <= MAX_PHOTOS && rows.count { |row| row["kind"] == "signature" } <= 1 && rows.all? { |row| row["id"].to_s.match?(UUID) && %w[photo signature].include?(row["kind"]) && row["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) } && rows.map { |row| row["id"] }.uniq.size == rows.size
      raise ArgumentError, "Las evidencias deben incluir hasta 4 fotos y una firma, sin repetir identificadores"
    end
    uploaded = user.company.delivery_evidences.where(user: user, evidence_uuid: rows.map { |row| row["id"] }).order(:id).lock.index_by { |row| row.evidence_uuid.to_s }
    rows.map do |row|
      record = uploaded[row["id"]]
      raise MissingUpload, "Falta subir una evidencia; se reintentará sin perder el registro local" unless record && record.file.attached? && !record.purged_at
      unless record.operation_id == operation_id && record.visit_id.to_s == visit_id.to_s && record.kind == row["kind"] && record.sha256 == row["sha256"] && record.driver_sync_operation_id.nil?
        raise ArgumentError, "Una evidencia pertenece a otro registro o su contenido cambió"
      end
      record
    end
  end

  private

  def valid_ownership
    same_company(:user)
    same_company(:driver_sync_operation)
    if driver_sync_operation && (driver_sync_operation.user_id != user_id || driver_sync_operation.operation_id != operation_id || driver_sync_operation.visit_id != visit_id)
      errors.add(:driver_sync_operation, "debe corresponder al mismo intento y repartidor")
    end
  end

  def immutable_evidence
    if (changes_to_save.keys - %w[driver_sync_operation_id purged_at updated_at]).any? || (driver_sync_operation_id_in_database && will_save_change_to_driver_sync_operation_id?)
      errors.add(:base, "La evidencia conserva su autor, contenido y registro originales")
    end
  end
end
