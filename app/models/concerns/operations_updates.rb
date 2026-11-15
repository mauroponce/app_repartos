module OperationsUpdates
  extend ActiveSupport::Concern

  included do
    after_commit :notify_operations
  end

  private

  def notify_operations
    # Tiny invalidations keep customer data out of the broadcast and out of
    # PostgreSQL NOTIFY's payload limit. The next HTTP request rechecks access.
    Turbo::StreamsChannel.broadcast_action_to(company, :operations, action: "operations_refresh")
    return if ENV["OSRM_URL"].blank?
    drivers = case self
    when DriverLocation then [ user_id ]
    when DeliveryRun then [ driver_id, previous_changes.dig("driver_id", 0) ]
    when Visit then [ delivery_run&.driver_id ]
    when DeliveryOrder then [ visit&.delivery_run&.driver_id ]
    end
    Array(drivers).compact.uniq.each { |id| OperationsEtaJob.perform_later(company_id, id) }
  rescue StandardError => error
    Rails.logger.warn("Operations broadcast unavailable: #{error.class.name}")
    # Polling recovers the committed state if Cable is temporarily unavailable.
  end
end
