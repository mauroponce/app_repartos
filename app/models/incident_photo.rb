class IncidentPhoto < ApplicationRecord
  include TenantIntegrity
  belongs_to :incident
  belongs_to :user
  has_one_attached :file
  validates :file_uuid, format: { with: DeliveryEvidence::UUID }, uniqueness: { scope: :company_id }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validate -> { same_company(:incident); same_company(:user) }
  before_destroy { errors.add(:base, "La fotografía conserva sus datos de auditoría"); throw :abort }
  validate do
    errors.add(:file, "adjuntá la fotografía") if new_record? && !file.attached?
    if file.attached? && (!file.blob.content_type.in?(%w[image/jpeg image/png image/webp]) || !file.blob.byte_size.between?(1, 2.megabytes))
      errors.add(:file, "usá una fotografía JPEG, PNG o WebP de hasta 2 MB")
    end
  end
  validate do
    errors.add(:base, "La fotografía conserva su origen") if persisted? && (changes_to_save.keys - %w[purged_at]).any?
  end
end
