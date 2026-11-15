require "test_helper"
require_relative "../test_helpers/workflow_test_helper"

class WorkflowPhotoUploadsTest < ActiveSupport::TestCase
  include WorkflowTestHelper
  include ActiveJob::TestHelper

  def upload(bytes, type = "image/png")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: "foto.png")
  end

  def manifest(bytes)
    { id: SecureRandom.uuid, sha256: Digest::SHA256.hexdigest(bytes) }
  end

  test "actual content size pixels checksums and attachment count are validated before storage" do
    png = Vips::Image.black(20, 20).write_to_buffer(".png")
    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(ArgumentError) { WorkflowPhotoUploads.prepare([ upload(png) ], [ manifest("changed") ]) }
      svg = "<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>"
      assert_raises(ArgumentError) { WorkflowPhotoUploads.prepare([ upload(svg) ], [ manifest(svg) ]) }
      too_large = "x" * (2.megabytes + 1)
      assert_raises(ArgumentError) { WorkflowPhotoUploads.prepare([ upload(too_large) ], [ manifest(too_large) ]) }
      huge_pixels = Vips::Image.black(4100, 4100).write_to_buffer(".png")
      assert_raises(ArgumentError) { WorkflowPhotoUploads.prepare([ upload(huge_pixels) ], [ manifest(huge_pixels) ]) }
      assert_raises(ArgumentError) { WorkflowPhotoUploads.prepare(5.times.map { upload(png) }, 5.times.map { manifest(png) }) }
      id = manifest(png)
      assert_raises(ArgumentError) { WorkflowPhotoUploads.prepare([ upload(png), upload(png) ], [ id, id ]) }
    end
  end

  test "retention purges only photographs of closed incidents and preserves original metadata" do
    company = companies(:one)
    incident = company.incidents.find(workflow_report.fetch("incident_id"))
    bytes = Vips::Image.black(30, 20).write_to_buffer(".png")
    photo = company.incident_photos.new(incident: incident, user: users(:driver), file_uuid: SecureRandom.uuid, sha256: Digest::SHA256.hexdigest(bytes))
    photo.file.attach(io: StringIO.new(bytes), filename: "foto.png", content_type: "image/png")
    photo.save!
    old = ENV["INCIDENT_PHOTO_RETENTION_DAYS"]
    ENV["INCIDENT_PHOTO_RETENTION_DAYS"] = "1"
    travel 3.days do
      IncidentPhotoRetentionJob.perform_now
      assert_nil photo.reload.purged_at
    end
    WorkflowActions.new(users(:one)).incident_action(id: incident.id, operation_id: SecureRandom.uuid, attributes: { version: 0, action: "resolve", message: "Se registró la reparación" })
    travel 3.days do
      assert_enqueued_with(job: ActiveStorage::PurgeJob) { IncidentPhotoRetentionJob.perform_now }
      assert_not_nil photo.reload.purged_at
      assert_equal Digest::SHA256.hexdigest(bytes), photo.sha256
      assert Incident.exists?(incident.id)
      assert_not photo.destroy
    end
  ensure
    ENV["INCIDENT_PHOTO_RETENTION_DAYS"] = old
  end
end
