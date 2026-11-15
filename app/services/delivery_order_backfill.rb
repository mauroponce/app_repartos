# Converts legacy scheduled visits without changing their identity or execution.
# When several legacy visits share a schedule/date, the first represents the
# occurrence; the remaining visits stay intact as historical execution records.
class DeliveryOrderBackfill
  def self.call(company:, date: nil, visit_ids: nil)
    company.with_lock do
      visits = company.visits.where.not(delivery_schedule_id: nil).joins(:delivery_run)
      visits = visits.where(delivery_runs: { scheduled_date: date }) if date
      visits = visits.where(id: visit_ids) if visit_ids
      converted = 0
      visits.includes(:delivery_run, :delivery_schedule, :delivery_items).order(:id).each do |visit|
        next if visit.delivery_orders.exists? || visit.delivery_items.empty?
        schedule = visit.delivery_schedule
        next if company.delivery_orders.exists?(delivery_schedule_id: schedule.id, scheduled_date: visit.delivery_run.scheduled_date)
        # Legacy visits never stored a time snapshot; do not invent one from
        # a recurrence that may have changed since execution.
        order = company.delivery_orders.new(customer_id: visit.customer_id, delivery_schedule: schedule, visit: visit,
          scheduled_date: visit.delivery_run.scheduled_date, customer_name: visit.customer_name, customer_address: visit.customer_address,
          notes: visit.notes)
        visit.delivery_items.each.with_index do |item, index|
          order.delivery_order_items.build(company: company, product_id: item.product_id, description: item.description, unit: item.unit,
            quantity: item.planned_quantity, position: index, copying_schedule_snapshot: true, preserve_commercial_snapshot: true, **item.attributes.slice(*CommercialSnapshot::FIELDS))
        end
        # Historical execution is imported atomically; normal editing rules apply
        # again after these new records have been created.
        order.save!(context: :historical_import)
        visit.delivery_items.zip(order.delivery_order_items).each do |execution, requested|
          execution.update_columns(delivery_order_item_id: requested.id)
        end
        order.update_columns(status: order.resolved_status) unless visit.pending?
        DeliveryStatusEvent.create!(company: company, delivery_order: order, to_status: order.status, source: "baseline", context: { visit_id: visit.id, run_id: visit.delivery_run_id })
        converted += 1
      end
      converted
    end
  end
end
