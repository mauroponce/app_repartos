module DriverDashboard
  private

  def assigned_runs
    Current.company.delivery_runs.published_to_driver.where(driver_id: Current.user.id)
  end

  def load_dashboard(run_id: params[:run_id])
    @driver_inbox ||= DriverInbox.new(Current.user)
    @today ||= Current.company.local_date
    @runs ||= assigned_runs.where(scheduled_date: @today, status: %w[assigned in_progress completed]).order(:id).to_a
    @run = run_id.present? ? @runs.find { |run| run.id.to_s == run_id.to_s } : (@runs.find { |run| !run.completed? } || @runs.first)
    raise ActiveRecord::RecordNotFound if run_id.present? && !@run
    @dashboard_visits ||= {}
    @visits = @run ? (@dashboard_visits[@run.id] ||= @run.visits.includes(:customer, :delivery_items, :delivery_schedule, :delivery_orders).to_a) : []
    @next_visit = @visits.find(&:pending?)
    @resolved_count = @visits.count { |visit| !visit.pending? }
    @completed_count = @visits.count(&:completed?)
    @progress = @visits.empty? ? 0 : (@resolved_count * 100.0 / @visits.size).round
    @markers = @visits.filter_map do |visit|
      next unless visit.customer.latitude && visit.customer.longitude
      { id: visit.id, position: visit.position, name: visit.customer_name, latitude: visit.customer.latitude.to_f,
        longitude: visit.customer.longitude.to_f, status: visit.status, current: visit == @next_visit }
    end
    week = @today.beginning_of_week..@today.end_of_week
    confirmed = Current.company.visits.where(confirmed_by_id: Current.user.id).where.not(confirmed_at: nil)
    completed = confirmed.completed
    zone_name = Time.zone.tzinfo.identifier
    @week_counts ||= completed.where(confirmed_at: week.first.beginning_of_day..week.last.end_of_day)
      .group("DATE(confirmed_at AT TIME ZONE 'UTC' AT TIME ZONE #{ActiveRecord::Base.connection.quote(zone_name)})").count
    @history ||= confirmed.where.not(status: :pending).order(confirmed_at: :desc, id: :desc).limit(10)
  end
end
