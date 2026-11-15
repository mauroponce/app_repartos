class DeliveryEvidenceRetentionJob < ApplicationJob
  def perform
    # Uploaded files whose operation never arrived can be re-uploaded from the
    # durable local queue. They are not finalized delivery evidence.
    DeliveryEvidence.where(driver_sync_operation_id: nil).where("created_at < ?", 7.days.ago).find_each do |evidence|
      evidence.company.with_lock do
        evidence.reload
        evidence.destroy! if evidence.driver_sync_operation_id.nil? && evidence.created_at < 7.days.ago
      end
    end
    ActiveStorage::Blob.unattached.where("active_storage_blobs.created_at < ?", 7.days.ago).find_each do |blob|
      blob.purge_later if blob.metadata["delivery_evidence"]
    end
    days = ENV["DELIVERY_EVIDENCE_RETENTION_DAYS"].presence
    return unless days
    days = Integer(days, 10)
    raise ArgumentError, "La conservación de evidencias requiere un número positivo de días" unless days.in?(1..36500)
    DeliveryEvidence.joins(:driver_sync_operation).where(driver_sync_operations: { status: "synced", created_at: ...days.days.ago }).where(purged_at: nil).find_each do |evidence|
      evidence.with_lock do
        next if evidence.purged_at
        evidence.update!(purged_at: Time.current)
        evidence.file.purge_later
      end
    end
  end
end
