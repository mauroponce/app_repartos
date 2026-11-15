require "test_helper"
require_relative "../test_helpers/delivery_evidence_test_helper"

class DeliveryProofsControllerTest < ActionDispatch::IntegrationTest
  include DeliveryEvidenceTestHelper
  setup { setup_proof_visit; sign_in_as @driver }
  teardown { clean_evidence_files }

  test "upload and sync endpoints return private authenticated evidence and a complete receipt" do
    attributes = evidence_upload
    post "/repartidor/api/v1/evidences", params: { evidence: attributes }
    assert_response :success
    assert_equal attributes[:evidence_uuid], response.parsed_body["id"]
    evidence = @company.delivery_evidences.last
    @evidence_blobs << evidence.file.blob
    assert_no_difference [ "DeliveryEvidence.count", "ActiveStorage::Blob.count" ] do
      post "/repartidor/api/v1/evidences", params: { evidence: evidence_upload(evidence_uuid: attributes[:evidence_uuid]) }
      assert_response :success
    end
    operation = proof_operation(evidences: [ evidence ])
    post "/repartidor/api/v1/operations", params: { operation: operation }, as: :json
    assert_response :success
    assert_equal "synced", response.parsed_body["status"]
    get delivery_evidence_path(evidence)
    assert_response :success
    assert_equal "image/jpeg", response.media_type
    assert_includes response.headers["Cache-Control"], "no-store"
    get delivery_receipt_path(@visit)
    assert_response :success
    assert_select "h1", text: "Comprobante de entrega ##{@visit.id}"
    assert_select "dd", text: "María"
    assert_select "img[src=?]", delivery_evidence_path(evidence)
    sign_in_as users(:one)
    get delivery_receipt_path(@visit)
    assert_response :success
    get delivery_evidence_path(evidence)
    assert_response :success
    get "/rails/active_storage/blobs/redirect/#{evidence.file.blob.signed_id}/photo.jpg"
    assert_response :not_found
  end

  test "evidence and receipts cannot be read by other tenants or another driver" do
    evidence = upload_evidence
    DriverOperationSync.call(user: @driver, attributes: proof_operation(evidences: [ evidence ]))
    [ users(:two), users(:other_driver), users(:inactive_driver) ].each do |user|
      sign_in_as user
      get delivery_evidence_path(evidence)
      assert response.not_found? || response.redirect?, response.status.to_s
      get delivery_receipt_path(@visit)
      assert response.not_found? || response.redirect?, response.status.to_s
    end
    sign_out
    get delivery_evidence_path(evidence)
    assert_redirected_to new_session_path
  end

  test "a storage failure is retryable and a missing manifest file cannot finalize a visit" do
    original = ActiveStorage::Blob.method(:create_and_upload!)
    ActiveStorage::Blob.define_singleton_method(:create_and_upload!) { |**_args| raise IOError, "storage unavailable" }
    post "/repartidor/api/v1/evidences", params: { evidence: evidence_upload }
    assert_response :service_unavailable
    assert @visit.reload.pending?
    post "/repartidor/api/v1/operations", params: { operation: proof_operation.merge(evidence: [ { id: SecureRandom.uuid, kind: "photo", sha256: "a" * 64 } ]) }, as: :json
    assert_response :service_unavailable
    assert @visit.reload.pending?
    assert_empty @company.driver_sync_operations
  ensure
    ActiveStorage::Blob.define_singleton_method(:create_and_upload!, original) if original
  end

  test "conflicts show their preserved files to administration without making a receipt" do
    evidence = upload_evidence
    operation = proof_operation(evidences: [ evidence ])
    @run.update!(driver: nil, status: :draft)
    post "/repartidor/api/v1/operations", params: { operation: operation }, as: :json
    assert_equal "conflict", response.parsed_body["status"]
    sign_in_as users(:one)
    get driver_sync_operation_path(@company.driver_sync_operations.last)
    assert_response :success
    assert_select "img[src=?]", delivery_evidence_path(evidence)
    get delivery_receipt_path(@visit)
    assert_response :not_found
  end

  test "new files cannot be appended after receipt confirmation" do
    DriverOperationSync.call(user: @driver, attributes: proof_operation)
    assert_no_difference [ "DeliveryEvidence.count", "ActiveStorage::Blob.count" ] do
      post "/repartidor/api/v1/evidences", params: { evidence: evidence_upload }
      assert_response :unprocessable_entity
    end
  end
end
