require "vips"

module DeliveryEvidenceTestHelper
  def setup_proof_visit
    @company, @driver = companies(:one), users(:driver)
    @order = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @company.local_date,
      delivery_order_items_attributes: [ { description: "Cajones", quantity: 20, unit: "box" } ])
    @run = @company.delivery_runs.new(name: "Comprobantes", scheduled_date: @order.scheduled_date, driver: @driver, status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ @order.id ])
    @visit = @order.reload.visit
    @proof = DriverWorkSnapshot.issue(user: @driver, visit: @visit)
    @operation_id = SecureRandom.uuid
    @evidence_files = []
    @evidence_blobs = []
  end

  def evidence_upload(kind: "photo", bytes: nil, **attributes)
    bytes ||= Vips::Image.black(32, 20, bands: 3).write_to_buffer(kind == "signature" ? ".png" : ".jpg")
    tempfile = Tempfile.new([ "evidence-test", ".png" ])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    @evidence_files << tempfile
    { operation_id: @operation_id, evidence_uuid: SecureRandom.uuid, visit_id: @visit.id, proof: @proof, kind: kind,
      sha256: Digest::SHA256.hexdigest(bytes), file: Rack::Test::UploadedFile.new(tempfile.path, "image/png") }.merge(attributes)
  end

  def upload_evidence(**options)
    record = DeliveryEvidenceUploader.call(user: @driver, attributes: evidence_upload(**options))
    @evidence_blobs << record.file.blob
    record
  end

  def proof_operation(evidences: [], **attributes)
    { operation_id: @operation_id, visit_id: @visit.id, proof: @proof, status: "completed", recorded_at: 10.minutes.ago.iso8601,
      receipt_version: 1, receiver_name: "María", failure_reason: nil, notes: "Entrega registrada",
      evidence: evidences.map { |record| { id: record.evidence_uuid, kind: record.kind, sha256: record.sha256 } },
      items: @visit.delivery_items.map { |item| { id: item.id, delivered_quantity: "20" } } }.merge(attributes)
  end

  def clean_evidence_files
    @evidence_files&.each(&:close!)
    @evidence_blobs&.each { |blob| blob.service.delete(blob.key) }
  end
end
