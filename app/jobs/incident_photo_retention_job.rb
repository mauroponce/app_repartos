class IncidentPhotoRetentionJob < ApplicationJob
  def perform
    ActiveStorage::Blob.unattached.where("active_storage_blobs.created_at < ?", 7.days.ago).find_each do |blob|
      blob.purge_later if blob.metadata["incident_photo"]
    end
    days = ENV["INCIDENT_PHOTO_RETENTION_DAYS"].presence
    return unless days
    days = Integer(days, 10)
    raise ArgumentError, "La conservación de fotos requiere un número positivo de días" unless days.in?(1..36500)
    IncidentPhoto.joins(:incident).where(incidents: { status: %w[resolved dismissed], resolved_at: ...days.days.ago }).where(purged_at: nil).find_each do |photo|
      photo.with_lock do
        next if photo.purged_at
        photo.update!(purged_at: Time.current)
        photo.file.purge_later
      end
    end
  end
end
