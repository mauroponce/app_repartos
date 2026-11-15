class DriverSyncOperation < ApplicationRecord
  include TenantIntegrity
  belongs_to :user
  has_many :delivery_evidences, dependent: :restrict_with_error
  enum :status, { synced: "synced", conflict: "conflict", invalid: "invalid" }, prefix: true, validate: true
  validates :operation_id, :payload_digest, :visit_id, presence: true
  validate -> { same_company(:user) }
  validate :preserve_receipt, on: :update

  def response_data
    { operation_id: operation_id, status: status, result: result }
  end

  private

  def preserve_receipt
    errors.add(:base, "El intento conserva su contenido y resultado originales") if has_changes_to_save?
  end
end
