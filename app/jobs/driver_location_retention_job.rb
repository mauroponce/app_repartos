class DriverLocationRetentionJob < ApplicationJob
  def perform
    DriverLocation.where(captured_at: ...DriverLocation.retention.ago).delete_all
  end
end
