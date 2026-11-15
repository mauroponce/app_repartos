class OperationsSnapshot
  attr_reader :company, :now, :runs, :orders, :locations, :counts, :overdue, :changes

  def initialize(company:, now: Time.current)
    @company, @now = company, now
    @runs = company.delivery_runs.where(scheduled_date: company.local_date).where.not(status: :cancelled)
      .includes(:driver, visits: [ :customer, :delivery_items, :delivery_orders ]).order(:id).to_a
    @orders = company.delivery_orders.where(scheduled_date: company.local_date).where.not(status: :cancelled)
      .includes({ delivery_order_items: :delivery_item }, visit: [ :delivery_run, :delivery_items, :delivery_orders ]).order(:id).to_a
    active_driver_ids = runs.select { |run| run.status.in?(%w[assigned in_progress]) && run.driver&.active? }.map(&:driver_id)
    @locations = company.driver_locations.joins(:user).includes(:user).where(users: { location_sharing_enabled: true })
      .where(sharing: true, user_id: active_driver_ids, captured_at: DriverLocation.retention.ago..).index_by(&:user_id)
    partial = orders.count { |order| order.needs_attention? && order.fulfillment_result == "partial" }
    @counts = { pending: orders.count(&:pending?), completed: orders.count(&:completed?),
      partial: partial, failed: orders.count(&:needs_attention?) - partial }
    @overdue = orders.select { |order| order.pending? && deadline(order) && deadline(order) < now }
    @changes = company.delivery_dispatch_changes.includes(:user, :delivery_order).order(id: :desc).limit(10)
  end

  def deadline(order)
    time = order.window_end || order.preferred_time
    return unless time
    zone.local(order.scheduled_date.year, order.scheduled_date.month, order.scheduled_date.day, time.hour, time.min, time.sec)
  end

  def estimates(run)
    location = locations[run.driver_id]
    data = location&.eta_data
    return [] unless location&.fresh? && data["run_id"] == run.id && data["signature"] == OperationsEta.signature(run)
    return [] unless Time.iso8601(data.fetch("calculated_at")) >= DriverLocation::FRESH_FOR.ago
    data.fetch("stops")
  rescue KeyError, ArgumentError
    []
  end

  def markers
    locations.values.map do |location|
      { id: location.user_id, name: runs.find { |run| run.driver_id == location.user_id }&.driver&.name,
        latitude: location.latitude.to_f, longitude: location.longitude.to_f, fresh: location.fresh?,
        fresh_for_ms: [ ((location.captured_at + DriverLocation::FRESH_FOR - now) * 1000).ceil, 0 ].max,
        captured_at: location.captured_at.in_time_zone(company.time_zone).strftime("%H:%M:%S"), accuracy: location.accuracy.to_f }
    end
  end

  def destination_runs
    company.delivery_runs.where(scheduled_date: company.local_date.., status: %w[assigned in_progress])
      .joins(:driver).merge(User.active).includes(:driver).order(:scheduled_date, :id)
  end

  private

  def zone
    ActiveSupport::TimeZone[company.time_zone]
  end
end
