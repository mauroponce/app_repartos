require "test_helper"
require_relative "../test_helpers/delivery_evidence_test_helper"

class DeliveryEvidenceTest < ActiveSupport::TestCase
  include DeliveryEvidenceTestHelper
  setup { setup_proof_visit }
  teardown { clean_evidence_files }

  test "uploads before confirming and creates a receipt with photos signature quantities time and GPS" do
    photo, signature = upload_evidence, upload_evidence(kind: "signature")
    assert @visit.reload.pending?
    operation = proof_operation(evidences: [ photo, signature ], failure_reason: "shortage", items: [ { id: @visit.delivery_items.first.id, delivered_quantity: "18" } ],
      location: { latitude: -34.8, longitude: -58.34, accuracy: 12.5, captured_at: 11.minutes.ago.iso8601 })
    receipt = DriverOperationSync.call(user: @driver, attributes: operation)
    assert receipt.status_synced?, receipt.result.inspect
    assert_equal [ photo.evidence_uuid, signature.evidence_uuid ], receipt.result["evidence_ids"]
    assert_equal receipt.id, photo.reload.driver_sync_operation_id
    assert_equal "shortage", @visit.reload.failure_reason
    assert_equal "María", @visit.receiver_name
    assert_equal 1, @visit.receipt_version
    assert_equal 18, @visit.delivery_items.first.delivered_quantity
    assert @order.reload.needs_attention?
    assert_in_delta 10.minutes.ago, @visit.recorded_at, 2
    assert_in_delta Time.current, @visit.confirmed_at, 2
    assert_equal(-34.8.to_d, @visit.recorded_latitude)
    assert_no_difference [ "DriverSyncOperation.count", "DeliveryEvidence.count", "ActiveStorage::Blob.count" ] do
      assert_equal receipt, DriverOperationSync.call(user: @driver, attributes: operation)
    end
  end

  test "missing files are retryable and never confirm a visit or create a partial receipt" do
    manifest = { id: SecureRandom.uuid, kind: "photo", sha256: "a" * 64 }
    assert_no_difference "DriverSyncOperation.count" do
      assert_raises(DeliveryEvidence::MissingUpload) { DriverOperationSync.call(user: @driver, attributes: proof_operation.merge(evidence: [ manifest ])) }
    end
    assert @visit.reload.pending?
    assert_nil @visit.delivery_items.first.delivered_quantity
  end

  test "partial failed and rejected receipts require a reason while invalid quantities roll back" do
    invalid = proof_operation(items: [ { id: @visit.delivery_items.first.id, delivered_quantity: "18" } ])
    receipt = DriverOperationSync.call(user: @driver, attributes: invalid)
    assert receipt.status_invalid?
    assert_match(/motivo/, receipt.result["message"])
    assert @visit.reload.pending?
    assert_nil @visit.delivery_items.first.delivered_quantity
    @operation_id = SecureRandom.uuid
    receipt = DriverOperationSync.call(user: @driver, attributes: proof_operation(status: "rejected", failure_reason: "rejected"))
    assert receipt.status_synced?, receipt.result.inspect
    assert @visit.reload.rejected?
    assert_equal 0, @visit.delivery_items.first.delivered_quantity
    assert @order.reload.needs_attention?
  end

  test "conflicts retain evidence and never overwrite server execution" do
    photo = upload_evidence
    operation = proof_operation(evidences: [ photo ])
    @run.update!(driver: nil, status: :draft)
    receipt = DriverOperationSync.call(user: @driver, attributes: operation)
    assert receipt.status_conflict?
    assert_equal receipt.id, photo.reload.driver_sync_operation_id
    assert photo.file.attached?
    assert @visit.reload.pending?
  end

  test "uploaded UUIDs cannot be replaced reassigned or injected into another operation" do
    attributes = evidence_upload
    photo = DeliveryEvidenceUploader.call(user: @driver, attributes: attributes)
    @evidence_blobs << photo.file.blob
    assert_no_difference [ "DeliveryEvidence.count", "ActiveStorage::Blob.count" ] do
      repeated = DeliveryEvidenceUploader.call(user: @driver, attributes: evidence_upload(evidence_uuid: attributes[:evidence_uuid]))
      assert_equal photo.id, repeated.id
    end
    assert_raises(DriverOperationSync::ReusedIdentifier) do
      DeliveryEvidenceUploader.call(user: @driver, attributes: evidence_upload(evidence_uuid: photo.evidence_uuid, bytes: Vips::Image.black(20, 20).write_to_buffer(".png")))
    end
    assert_raises(ArgumentError) do
      DriverOperationSync.call(user: @driver, attributes: proof_operation(evidences: [ photo ], operation_id: SecureRandom.uuid))
    end
    assert_raises(DriverOperationSync::Unauthorized) { DeliveryEvidenceUploader.call(user: users(:other_driver), attributes: evidence_upload) }
  end

  test "validates actual image bytes checksum pixel count and file count" do
    [ "<svg><script>alert(1)</script></svg>", "not an image" ].each do |bytes|
      assert_raises(ArgumentError) { DeliveryEvidenceUploader.call(user: @driver, attributes: evidence_upload(bytes: bytes)) }
    end
    assert_raises(ArgumentError) { DeliveryEvidenceUploader.call(user: @driver, attributes: evidence_upload(sha256: "f" * 64)) }
    oversized = "x" * (DeliveryEvidence::PHOTO_LIMIT + 1)
    assert_raises(ArgumentError) { DeliveryEvidenceUploader.call(user: @driver, attributes: evidence_upload(bytes: oversized)) }
    4.times { upload_evidence }
    assert_raises(ArgumentError) { upload_evidence }
    upload_evidence(kind: "signature")
    assert_raises(ArgumentError) { upload_evidence(kind: "signature") }
    assert_equal 5, @company.delivery_evidences.count
  end

  test "normalizes photos and strips source metadata before serving" do
    image = Vips::Image.black(1800, 40, bands: 3)
    image.set_type(GObject::GSTR_TYPE, "image-description", "private device metadata")
    photo = upload_evidence(bytes: image.write_to_buffer(".png"))
    output = Vips::Image.new_from_buffer(photo.file.download, "")
    assert_operator output.width, :<=, 1600
    assert_equal 0, output.get_typeof("image-description")
    assert_equal "image/jpeg", photo.file.blob.content_type
  end
end
