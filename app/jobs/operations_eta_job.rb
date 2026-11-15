class OperationsEtaJob < ApplicationJob
  limits_concurrency to: 1, key: ->(company_id, user_id) { "eta:#{company_id}:#{user_id}" }, duration: 1.minute
  def perform(company_id, user_id)
    company = Company.find_by(id: company_id)
    return unless company
    location = company.driver_locations.find_by(user_id: user_id)
    return unless location&.fresh?
    run = company.delivery_runs.published_to_driver.where(driver_id: user_id, scheduled_date: company.local_date, status: %w[in_progress assigned])
      .order(Arel.sql("CASE WHEN status = 'in_progress' THEN 0 ELSE 1 END"), :id)
      .includes(visits: [ :customer, :delivery_items, :delivery_orders ]).find { |candidate| candidate.visits.any?(&:pending?) }
    return unless run
    version = location.updated_at
    signature = OperationsEta.signature(run)
    previous = location.eta_data
    if previous["run_id"] == run.id && previous["signature"] == signature && Time.iso8601(previous.fetch("calculated_at")) >= 30.seconds.ago
      return
    end
    data = OperationsEta.call(run: run, location: location)
    company.with_lock do
      location.reload
      run.reload
      return unless location.updated_at == version && location.fresh? && OperationsEta.signature(run) == signature
      # Avoid recursively enqueueing another estimate from the location callback.
      location.update_columns(eta_data: data)
      Turbo::StreamsChannel.broadcast_action_to(company, :operations, action: "operations_refresh")
    end
  rescue OperationsEta::Unavailable => error
    Rails.logger.info("Operations ETA unavailable: #{error.class.name}")
  rescue ActiveRecord::RecordNotFound
    # The location or plan was removed while the router was responding.
  end
end
