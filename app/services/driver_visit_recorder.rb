class DriverVisitRecorder
  class Conflict < StandardError; end

  def self.call(user:, visit_id:, attributes:)
    user.company.with_lock do
      run = user.company.delivery_runs.where(driver_id: user.id).joins(:visits).find_by!(visits: { id: visit_id })
      run.lock!
      visit = run.visits.find(visit_id)
      visit.lock!
      unless run.scheduled_date == user.company.local_date && (run.assigned? || run.in_progress?) && visit.pending?
        raise Conflict, "La parada ya fue resuelta o la hoja ya no permite registrar entregas. Actualizá tu ruta."
      end

      status = attributes[:status]
      unless %w[completed not_attended closed rescheduled].include?(status)
        raise ArgumentError, "Elegí un resultado válido para la visita."
      end
      if status != "completed" && attributes[:notes].blank?
        raise ArgumentError, "Indicá el motivo de la incidencia."
      end
      raise ArgumentError, "Las observaciones admiten hasta 4.000 caracteres." if attributes[:notes].to_s.length > 4000

      items = visit.delivery_items.to_a
      quantities = Array(attributes[:items])
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

      visit.update!(status: status, notes: [ visit.notes.presence, attributes[:notes].presence ].compact.join("\n"))
      run.update!(status: run.visits.pending.exists? ? :in_progress : :completed)
      visit
    end
  end
end
