class DriverLocationRetentionJob < ApplicationJob
  def perform
    DriverLocation.where(captured_at: ...24.hours.ago).delete_all
  end
end
