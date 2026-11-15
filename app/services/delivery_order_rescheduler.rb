class DeliveryOrderRescheduler
  def self.call(company:, order_id:, date:)
    company.with_lock do
      original = company.delivery_orders.find(order_id)
      date = Date.iso8601(date.to_s)
      if (existing = original.rescheduled_order)
        raise ArgumentError, "La entrega ya fue reprogramada para otra fecha" unless existing.scheduled_date == date
        return existing
      end
      raise ArgumentError, "La entrega no tiene faltantes conocidos para reprogramar" unless original.reschedulable?

      replacement = company.delivery_orders.new(original.attributes.slice("customer_id", "customer_name", "customer_address", "preferred_time", "window_start", "window_end", "notes"))
      replacement.assign_attributes(scheduled_date: date, rescheduled_from: original)
      original.delivery_order_items.includes(:delivery_item).each do |item|
        remaining = item.remaining_quantity
        next unless remaining.positive?
        replacement.delivery_order_items.build(item.attributes.slice("product_id", "description", "unit", "position").merge(
          company: company, quantity: remaining, copying_schedule_snapshot: true, preserve_commercial_snapshot: true, **item.attributes.slice(*CommercialSnapshot::FIELDS)))
      end
      replacement.save!
      replacement
    end
  end
end
