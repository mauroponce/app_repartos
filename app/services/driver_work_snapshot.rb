class DriverWorkSnapshot
  PURPOSE = "driver-offline-work-v1"
  LIFETIME = 48.hours
  LEGACY_ITEM_FIELDS = %w[id company_id visit_id product_id description unit planned_quantity delivered_quantity notes created_at updated_at delivery_order_item_id].freeze

  def self.package_revision(run:, runs:, visits:, date:)
    Digest::SHA256.hexdigest([ date, runs.map { |row| row.attributes.slice("id", "name", "status", "assignment_version") },
      run&.id, visits.map { |visit| [ revision(visit), visit.attributes.slice(*Visit::TIMING_FIELDS) ] } ].to_json)
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
      visit.delivery_items.order(:id).map { |item| item.attributes.slice(*item_fields) },
      visit.delivery_orders.order(:id).map { |order| order.attributes.slice("id", "preferred_time", "window_start", "window_end", "notes", "updated_at") } ]
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
      "items" => visit.delivery_items.order(:id).map { |item| item.attributes.slice("id", "description", "unit", "planned_quantity") } }
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
