class DriverVisitRecorder
  class Conflict < StandardError; end

  def self.call(user:, visit_id:, attributes:, offline_proof: nil)
    AuditContext.set(user: user, source: offline_proof ? "offline" : "driver") do
      record(user: user, visit_id: visit_id, attributes: attributes, offline_proof: offline_proof)
    end
  end

  def self.record(user:, visit_id:, attributes:, offline_proof: nil)
    user.company.with_lock do
      run = user.company.delivery_runs.where(driver_id: user.id).joins(:visits).find_by!(visits: { id: visit_id })
      run.lock!
      raise Conflict, "Administración está preparando el recorrido definitivo. Actualizá tu ruta cuando esté listo." if run.routing_blocked?
      visit = run.visits.find(visit_id)
      visit.lock!
      if offline_proof
        raise Conflict, "La visita ya fue confirmada desde otro dispositivo o administración." unless visit.pending?
        raise Conflict, "La descarga superó las 48 horas. Administración debe revisar el intento." if offline_proof["expires_at"].to_i < Time.current.to_i
        unless offline_proof["visit_id"].to_s == visit.id.to_s && DriverWorkSnapshot.matches?(visit, offline_proof)
          raise Conflict, "Cambió la planificación o la asignación desde la descarga. Administración debe revisar el intento."
        end
      end
      unless (offline_proof || run.scheduled_date == user.company.local_date) && (run.assigned? || run.in_progress?) && visit.pending?
        raise Conflict, "La parada ya fue resuelta o la hoja ya no permite registrar entregas. Actualizá tu ruta."
      end

      status = attributes[:status]
      unless %w[completed not_attended closed rescheduled rejected].include?(status)
        raise ArgumentError, "Elegí un resultado válido para la visita."
      end
      if status != "completed" && attributes[:notes].blank? && attributes[:failure_reason].blank?
        raise ArgumentError, "Indicá el motivo de la incidencia."
      end
      raise ArgumentError, "Las observaciones admiten hasta 4.000 caracteres." if attributes[:notes].to_s.length > 4000

      items = visit.delivery_items.to_a
      quantities = Array(attributes[:items])
      receipt = attributes[:receipt_version].present?
      if receipt
        raise ArgumentError, "Actualizá la aplicación para registrar este comprobante" unless attributes[:receipt_version].to_i == 1
        partial = status == "completed" && quantities.any? do |row|
          planned = items.find { |item| item.id.to_s == row[:id].to_s }
          planned && row[:delivered_quantity].to_d < planned.planned_quantity
        end
        raise ArgumentError, "Elegí el motivo de la entrega parcial o fallida" if (partial || status != "completed") && attributes[:failure_reason].blank?
        raise ArgumentError, "Describí el motivo en observaciones" if attributes[:failure_reason] == "other" && attributes[:notes].blank?
        recorded_at = Time.iso8601(attributes[:recorded_at].to_s)
        visit.assign_attributes(receipt_version: 1, recorded_at: recorded_at, recorded_at_source: "device", receiver_name: attributes[:receiver_name].to_s.strip.presence,
          failure_reason: attributes[:failure_reason].presence)
        if (location = attributes[:location]).present?
          visit.assign_attributes(recorded_latitude: location.fetch(:latitude), recorded_longitude: location.fetch(:longitude),
            location_accuracy: location.fetch(:accuracy), location_captured_at: Time.iso8601(location.fetch(:captured_at).to_s))
        end
      end
      if status == "completed"
        ids = quantities.map { |item| item[:id].to_s }
        unless ids.uniq.size == ids.size && ids.sort == items.map { |item| item.id.to_s }.sort && quantities.all? { |item| item[:delivered_quantity].present? }
          raise ArgumentError, "Registrá la cantidad entregada de cada producto, incluso cero."
        end
        quantities.each do |values|
          items.find { |item| item.id.to_s == values[:id].to_s }.update!(delivered_quantity: values[:delivered_quantity])
        end
      else
        if items.any? { |item| item.delivered_quantity.to_d.positive? }
          raise Conflict, "La visita ya tiene cantidades entregadas. Revisala con administración."
        end
        items.each { |item| item.update!(delivered_quantity: 0) }
      end

      visit.update!(status: status, confirmed_by: user, notes: [ visit.notes.presence, attributes[:notes].presence ].compact.join("\n"))
      run.update!(status: run.visits.pending.exists? ? :in_progress : :completed)
      visit
    end
  end
end
