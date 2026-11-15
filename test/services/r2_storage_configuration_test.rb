require "test_helper"
require "aws-sdk-s3"

class R2StorageConfigurationTest < ActiveSupport::TestCase
  test "R2 service uses private S3 requests and the configured compatibility options" do
    ActiveStorage::Blob.service
    settings = Rails.configuration.active_storage.service_configurations.deep_symbolize_keys
    settings[:r2] = settings.fetch(:r2).merge(access_key_id: "test-key", secret_access_key: "test-secret",
      bucket: "test-evidence", endpoint: "https://test-account.r2.cloudflarestorage.com", stub_responses: true)
    service = ActiveStorage::Service.configure(:r2, settings)
    checksum = Digest::MD5.base64digest("proof bytes")
    service.upload("test-file", StringIO.new("proof bytes"), checksum: checksum, content_type: "image/jpeg")
    request = service.client.client.api_requests.last
    assert_equal :put_object, request[:operation_name]
    assert_equal "test-evidence", request[:params][:bucket]
    assert_nil request[:params][:acl]
    assert_nil request[:params][:checksum_algorithm]
    assert_equal "auto", service.client.client.config.region
    assert_equal "when_required", service.client.client.config.request_checksum_calculation
    assert_not service.public?
  end
end
