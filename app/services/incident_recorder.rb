class IncidentRecorder
  def self.report(user:, operation_id:, attributes:, photos: [])
    raise WorkflowCommands::Forbidden unless user.driver?
    values = attributes.symbolize_keys
    WorkflowCommands.call(user: user, operation_id: operation_id, payload: { type: "incident_report", attributes: values }) do
      raise WorkflowCommands::Forbidden unless user.driver?
      visit = user.company.visits.joins(:delivery_run).where(delivery_runs: { driver_id: user.id }).find(values[:visit_id]) if values[:visit_id].present?
      run = visit&.delivery_run
      run ||= user.company.delivery_runs.where(driver_id: user.id).find(values[:delivery_run_id]) if values[:delivery_run_id].present?
      if values[:visit_id].present? && values[:delivery_run_id].present? && visit.delivery_run_id.to_s != values[:delivery_run_id].to_s
        raise ArgumentError, "La visita no corresponde a la ruta"
      end
      at = Time.iso8601(values[:occurred_at].to_s)
      raise ArgumentError, "El horario informado no es válido" if at > 5.minutes.from_now || at < 7.days.ago
      incident = user.company.incidents.create!(reporter: user, driver: user, visit: visit, delivery_run: run, customer: visit&.customer,
        source_key: "manual:#{operation_id}", kind: values[:kind], priority: values[:priority].presence || "normal", description: values[:description], occurred_at: at,
        context: visit ? snapshot(visit) : { run_name: run&.name })
      photos.each do |photo|
        record = user.company.incident_photos.new(incident: incident, user: user, file_uuid: photo.fetch(:id), sha256: photo.fetch(:sha256))
        record.file.attach(photo.fetch(:blob))
        record.save!
      end
      user.company.workflow_events.create!(incident: incident, user: user, action: "reported", message: incident.description)
      { incident_id: incident.id, attachment_ids: photos.map { |photo| photo.fetch(:id) } }
    end
  end

  def self.from_visit(visit)
    return if visit.pending?
    items = visit.delivery_items.to_a
    partial = visit.completed? && items.any? { |item| item.delivered_quantity && item.delivered_quantity < item.planned_quantity }
    return if visit.completed? && !partial
    visit.company.with_lock do
      key = "visit:#{visit.id}:execution"
      return visit.company.incidents.find_by(source_key: key) if visit.company.incidents.exists?(source_key: key)
      kind = { "not_attended" => "absent", "closed" => "closed", "rejected" => "rejected", "rescheduled" => "other" }[visit.status] || "shortage"
      reason = { "absent" => "absent", "closed" => "closed", "rejected" => "rejected", "shortage" => "shortage", "damaged" => "damaged", "customer_request" => "other", "other" => "other" }[visit.failure_reason]
      existing = visit.company.incidents.unresolved.find_by(visit_id: visit.id, kind: reason || kind)
      if existing
        unless existing.workflow_events.exists?(action: "execution_recorded")
          visit.company.workflow_events.create!(incident: existing, user: visit.confirmed_by, action: "execution_recorded", message: "Resultado original de la visita registrado", changeset: snapshot(visit))
        end
        return existing
      end
      incident = visit.company.incidents.create!(source_key: key, source: "automatic", reporter: visit.confirmed_by,
        driver: visit.confirmed_by&.driver? ? visit.confirmed_by : visit.delivery_run.driver, delivery_run: visit.delivery_run, visit: visit, customer: visit.customer,
        kind: reason || kind, description: visit.notes.presence || (partial ? "Entrega con cantidades inferiores a las planificadas" : "Visita finalizada sin entrega"),
        occurred_at: visit.confirmed_at || visit.completed_at, context: snapshot(visit))
      visit.company.workflow_events.create!(incident: incident, user: visit.confirmed_by, action: "detected", message: "Incidencia detectada desde la ejecución. No modifica el registro original.")
      incident
    end
  end

  def self.snapshot(visit)
    { visit_id: visit.id, run_id: visit.delivery_run_id, customer_name: visit.customer_name, customer_address: visit.customer_address, visit_status: visit.status,
      order_ids: visit.delivery_orders.pluck(:id), items: visit.delivery_items.map { |item| item.attributes.slice("id", "product_id", "description", "unit", "planned_quantity", "delivered_quantity") } }
  end
end
