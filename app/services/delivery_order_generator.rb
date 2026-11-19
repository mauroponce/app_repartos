class DeliveryOrderGenerator
  def self.call(company:, date:, schedule_ids: nil)
    date = if date.is_a?(Time) || date.is_a?(ActiveSupport::TimeWithZone)
      date.in_time_zone(company.time_zone).to_date
    else
      Date.iso8601(date.to_s)
    end
    company.with_lock do
      DeliveryOrderBackfill.call(company: company, date: date) if schedule_ids.nil?
      historical = company.visits.joins(:delivery_run).where(delivery_runs: { scheduled_date: date }).where.not(delivery_schedule_id: nil).pluck(:delivery_schedule_id)
      schedules = company.delivery_schedules.applicable_on(date)
      schedules = schedules.where(id: schedule_ids) if schedule_ids
      schedules.includes(:customer, :delivery_schedule_items).order(:id).each do |schedule|
        next if schedule.operation_kind == "visita_semanal" || historical.include?(schedule.id) || company.delivery_orders.exists?(delivery_schedule_id: schedule.id, scheduled_date: date)
        order = company.delivery_orders.new(customer: schedule.customer, delivery_schedule: schedule, scheduled_date: date,
          preferred_time: schedule.preferred_time, window_start: schedule.window_start, window_end: schedule.window_end, notes: schedule.notes, driver_profile: schedule.driver_profile)
        schedule.delivery_schedule_items.each do |item|
          order.delivery_order_items.build(company: company, product_id: item.product_id, description: item.description, unit: item.unit,
            quantity: item.quantity, position: item.position, copying_schedule_snapshot: true)
        end
        order.save!
      end
      company.delivery_orders.where(scheduled_date: date).where.not(delivery_schedule_id: nil).order(:id).to_a
    end
  end
end
