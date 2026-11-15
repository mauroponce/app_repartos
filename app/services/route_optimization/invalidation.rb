module RouteOptimization
  class Invalidation
    FIELDS = {
      "Customer" => %w[latitude longitude address city],
      "Visit" => %w[customer_id customer_address delivery_schedule_id position],
      "DeliveryOrder" => %w[visit_id preferred_time window_start window_end service_minutes],
      "DeliverySchedule" => %w[preferred_time window_start window_end],
      "DeliveryRun" => %w[scheduled_date routing_origin routing_return_to_depot],
      "Company" => %w[time_zone depot_latitude depot_longitude routing_departure routing_return_to_depot routing_preferred_tolerance routing_service_minutes]
    }.freeze

    def self.call(record, destroying: false)
      return [] if Current.applying_route_optimization
      fields = FIELDS.fetch(record.class.name)
      return [] unless destroying || record.new_record? || (record.changes_to_save.keys & fields).any?
      company_id = record.is_a?(Company) ? record.id : record.company_id
      return [] unless company_id
      runs = DeliveryRun.where(company_id: company_id, status: %w[draft assigned])
      runs = case record
      when Customer then runs.where(id: Visit.where(customer_id: record.id).select(:delivery_run_id))
      when Visit then runs.where(id: record.delivery_run_id)
      when DeliveryOrder
        runs.where(id: Visit.where(id: [ record.visit_id, record.visit_id_in_database ].compact).select(:delivery_run_id))
      when DeliverySchedule then runs.where(id: Visit.where(delivery_schedule_id: record.id).select(:delivery_run_id))
      when DeliveryRun then runs.where(id: record.id)
      else runs
      end
      publications = RoutePublication.where(company_id: company_id, delivery_run_id: runs.select(:id)).where.not(state: "manual")
      return [] unless publications.exists?
      # Taken before the edited row is written: same lock order as application.
      Company.where(id: company_id).lock.pick(:id)
      ids = []
      publications.includes(delivery_run: { visits: :delivery_items }).find_each(batch_size: 50) do |row|
        ids << row.delivery_run_id if row.delivery_run.editable?
      end
      superseded = RoutePublication.where(company_id: company_id, delivery_run_id: ids).select(:proposal_id)
      RouteOptimizationProposal.where(company_id: company_id, id: superseded, auto_publish: true, status: %w[queued processing ready])
        .update_all(status: "discarded", error_message: "Superada por cambios en los datos del recorrido.", updated_at: Time.current)
      RoutePublication.where(company_id: company_id, delivery_run_id: ids).update_all(state: "pending", proposal_id: nil, error_message: nil, updated_at: Time.current)
      DeliveryRun.where(company_id: company_id, id: ids).update_all("assignment_version = assignment_version + 1")
      ids
    end
  end
end
