class DeliveryRunReorderer
  def self.call(company:, delivery_run:, visit_ids:)
    company.with_lock do
      run = company.delivery_runs.find(delivery_run.id)
      raise ArgumentError, "La hoja ya no admite cambios de orden" unless run.editable?
      ids = Array(visit_ids).map(&:to_s)
      visits = run.visits.index_by { |visit| visit.id.to_s }
      raise ArgumentError, "El orden debe incluir cada parada una sola vez" unless ids.uniq.size == ids.size && ids.sort == visits.keys.sort
      ids.each.with_index(1) { |id, position| visits.fetch(id).update!(position: position) }
      run
    end
  end
end
