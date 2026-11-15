class DriverWorkSnapshot
  PURPOSE = "driver-offline-work-v1"
  LIFETIME = 48.hours
  LEGACY_ITEM_FIELDS = %w[id company_id visit_id product_id description unit planned_quantity delivered_quantity notes created_at updated_at delivery_order_item_id].freeze

  # MVCC gives all queries/rendering the same committed planning state without
  # blocking dispatch or another driver. Existing write locks and grant checks
  # still arbitrate confirmations made after a concurrent reassignment.
  def self.consistent_read
    company_id, user = Current.company.id, Current.user
    ApplicationRecord.transaction(isolation: :repeatable_read) do
      user.reload
      unless user.company_id == company_id && user.active? && user.driver? && Session.where(id: Current.session.id, user_id: user.id).exists?
        raise DriverOperationSync::Unauthorized
      end
      Time.use_zone(user.company.time_zone) do
        Current.driver_work_revision = work_revision(user: user, session_id: Current.session.id)
        yield
      end
    end
  end

  def self.work_revision(user:, session_id:)
    company = user.company
    today = company.local_date
    runs = company.delivery_runs.published_to_driver.where(driver_id: user.id, scheduled_date: today, status: %w[assigned in_progress completed])
    visits = company.visits.where(delivery_run_id: runs.select(:id))
    confirmed = company.visits.where(confirmed_by_id: user.id).where.not(confirmed_at: nil)
    content = [ "work-v1", presentation_revision, session_id, today, Time.current.to_i / 1.hour.to_i,
      company.attributes.slice("id", "name", "slug", "time_zone", "currency"), user.attributes.slice("id", "company_id", "name", "phone", "email_address", "role", "status"),
      records(runs), records(visits),
      records(company.customers.where(id: visits.select(:customer_id))),
      records(company.delivery_items.where(visit_id: visits.select(:id))),
      records(company.delivery_orders.where(visit_id: visits.select(:id))),
      records(company.delivery_schedules.where(id: visits.select(:delivery_schedule_id))),
      records(company.route_publications.where(delivery_run_id: company.delivery_runs.where(driver_id: user.id, scheduled_date: today).select(:id))),
      confirmed.order(confirmed_at: :desc, id: :desc).limit(10).pluck(*Visit.column_names),
      confirmed.completed.where(confirmed_at: today.beginning_of_week.beginning_of_day..today.end_of_week.end_of_day).order(:id).pluck(:id, :confirmed_at),
      DriverInbox.new(user).pending_count ]
    Digest::SHA256.hexdigest(content.to_json)
  end

  def self.records(scope)
    scope.reorder(:id).pluck(*scope.klass.column_names)
  end
  private_class_method :records

  def self.presentation_revision
    @presentation_revision ||= Digest::SHA256.hexdigest(Dir[Rails.root.join("app/views/repartidor/**/*"), Rails.root.join("app/helpers/*")].select { |path| File.file?(path) }.sort.map { |path| File.read(path) }.join)
  end

  def self.package_revision(run:, runs:, visits:, date:)
    Digest::SHA256.hexdigest([ date, runs.map { |row| row.attributes.slice("id", "name", "status", "assignment_version") },
      Current.driver_work_revision, run&.id, visits.map { |visit| [ revision(visit), visit.attributes.slice(*Visit::TIMING_FIELDS) ] } ].to_json)
  end

  def self.matches?(visit, proof)
    proof["revision"] == revision(visit, version: proof.fetch("revision_version", 2))
  end

  def self.revision(visit, version: 3)
    run = visit.delivery_run
    visit_fields = %w[id status customer_name customer_address position notes]
    visit_fields << "updated_at" if version.to_i < 3
    item_fields = version.to_i < 3 ? LEGACY_ITEM_FIELDS : LEGACY_ITEM_FIELDS + CommercialSnapshot::FIELDS
    content = [ run.id, run.driver_id, run.scheduled_date, run.assignment_version,
      visit.attributes.slice(*visit_fields),
      visit.delivery_items.sort_by(&:id).map { |item| item.attributes.slice(*item_fields) },
      visit.delivery_orders.sort_by(&:id).map { |order| order.attributes.slice("id", "preferred_time", "window_start", "window_end", "notes", "updated_at") } ]
    Digest::SHA256.hexdigest(content.to_json)
  end

  def self.issue(user:, visit:)
    return if visit.delivery_run.routing_blocked?
    return unless visit.pending? && visit.delivery_run.scheduled_date == user.company.local_date
    verifier.generate({ "company_id" => user.company_id, "user_id" => user.id, "visit_id" => visit.id,
      "revision" => revision(visit), "revision_version" => 3, "issued_at" => Time.current.to_i, "expires_at" => LIFETIME.from_now.to_i,
      "snapshot" => snapshot(visit) }, purpose: PURPOSE)
  end

  def self.recording_data(user:, visit:)
    snapshot(visit).merge("id" => visit.id, "revision" => revision(visit), "proof" => issue(user: user, visit: visit))
  end

  def self.snapshot(visit)
    { "customer_name" => visit.customer_name, "customer_address" => visit.customer_address, "position" => visit.position,
      "items" => visit.delivery_items.sort_by(&:id).map { |item| item.attributes.slice("id", "description", "unit", "planned_quantity") } }
  end

  def self.read(proof)
    verifier.verified(proof.to_s, purpose: PURPOSE)
  rescue ArgumentError
    nil
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
end
