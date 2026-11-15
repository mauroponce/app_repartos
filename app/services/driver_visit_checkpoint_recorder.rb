class DriverVisitCheckpointRecorder
  def self.call(user:, visit_id:, checkpoint:, occurred_at:, offline_proof:)
    user.company.with_lock do
      raise DriverOperationSync::Unauthorized unless user.reload.active? && user.driver?
      run = user.company.delivery_runs.where(driver_id: user.id).joins(:visits).find_by!(visits: { id: visit_id })
      raise DriverVisitRecorder::Conflict, "Administración está preparando el recorrido definitivo" if run.routing_blocked?
      visit = run.visits.find(visit_id)
      unless visit.pending? && run.status.in?(%w[assigned in_progress]) &&
          offline_proof["expires_at"].to_i >= Time.current.to_i && DriverWorkSnapshot.matches?(visit, offline_proof)
        raise DriverVisitRecorder::Conflict, "Cambió la parada o su asignación; administración debe revisar el horario registrado"
      end
      raise ArgumentError, "Etapa de visita inválida" unless Visit::TIMING_FIELDS.include?(checkpoint)
      time = Time.iso8601(occurred_at.to_s)
      if time > 5.minutes.from_now || time < Time.at(offline_proof.fetch("issued_at")) - 5.minutes
        raise ArgumentError, "El horario debe ser posterior a la descarga de la ruta y no estar en el futuro"
      end
      previous = visit.public_send(checkpoint)
      if previous
        raise DriverVisitRecorder::Conflict, "La etapa ya fue registrada con otro horario" unless previous == time
        return visit
      end
      visit.public_send("#{checkpoint}=", time)
      # A checkpoint does not change the plan shown on already-downloaded
      # confirmation forms, including forms from the previous PWA version.
      visit.save!(touch: false)
      run.update!(status: :in_progress) if run.assigned?
      visit
    end
  end
end
