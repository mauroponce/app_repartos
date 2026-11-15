require "test_helper"
require_relative "../test_helpers/delivery_evidence_test_helper"

class DeliveryEvidenceRetentionJobTest < ActiveSupport::TestCase
  include DeliveryEvidenceTestHelper
  setup do
    setup_proof_visit
    @original_retention = ENV["DELIVERY_EVIDENCE_RETENTION_DAYS"]
    ENV.delete("DELIVERY_EVIDENCE_RETENTION_DAYS")
  end
  teardown do
    ENV["DELIVERY_EVIDENCE_RETENTION_DAYS"] = @original_retention
    clean_evidence_files
  end

  test "retention defaults to keeping finalized evidence" do
    evidence = upload_evidence
    DriverOperationSync.call(user: @driver, attributes: proof_operation(evidences: [ evidence ]))
    travel 400.days do
      DeliveryEvidenceRetentionJob.perform_now
      assert evidence.reload.file.attached?
      assert_nil evidence.purged_at
    end
  end

  test "configured retention purges synced files while retaining the receipt and audit metadata" do
    evidence = upload_evidence
    operation = DriverOperationSync.call(user: @driver, attributes: proof_operation(evidences: [ evidence ]))
    ENV["DELIVERY_EVIDENCE_RETENTION_DAYS"] = "1"
    travel 2.days do
      DeliveryEvidenceRetentionJob.perform_now
      assert evidence.reload.purged_at
      assert_not evidence.file.attached?
      assert_equal operation.id, evidence.driver_sync_operation_id
      assert_equal evidence.evidence_uuid, operation.result["evidence_ids"].first
    end
  end

  test "a lost receipt acknowledgement can retry after file expiry without restoring deleted files" do
    evidence = upload_evidence
    input = proof_operation(evidences: [ evidence ])
    original = DriverOperationSync.call(user: @driver, attributes: input)
    ENV["DELIVERY_EVIDENCE_RETENTION_DAYS"] = "1"
    travel 2.days do
      DeliveryEvidenceRetentionJob.perform_now
      assert_no_difference "ActiveStorage::Blob.count" do
        duplicate = DeliveryEvidenceUploader.call(user: @driver, attributes: evidence_upload(evidence_uuid: evidence.evidence_uuid))
        assert_equal evidence.id, duplicate.id
        assert_not duplicate.file.attached?
        assert_equal original, DriverOperationSync.call(user: @driver, attributes: input)
      end
    end
  end

  test "conflicting receipts keep their evidence even when synced retention is enabled" do
    evidence = upload_evidence
    input = proof_operation(evidences: [ evidence ])
    @run.update!(driver: nil, status: :draft)
    receipt = DriverOperationSync.call(user: @driver, attributes: input)
    assert receipt.status_conflict?
    ENV["DELIVERY_EVIDENCE_RETENTION_DAYS"] = "1"
    travel 10.days do
      DeliveryEvidenceRetentionJob.perform_now
      assert evidence.reload.file.attached?
      assert_nil evidence.purged_at
    end
  end

  test "abandoned staged uploads are removed after seven days and invalid retention never expires finalized files" do
    evidence = upload_evidence
    travel 8.days do
      assert_difference "DeliveryEvidence.count", -1 do
        DeliveryEvidenceRetentionJob.perform_now
      end
      assert_not DeliveryEvidence.exists?(evidence.id)
    end
    ENV["DELIVERY_EVIDENCE_RETENTION_DAYS"] = "0"
    assert_raises(ArgumentError) { DeliveryEvidenceRetentionJob.perform_now }
  end
end
