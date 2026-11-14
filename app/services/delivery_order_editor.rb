class DeliveryOrderEditor
  def self.call(order:, attributes: {}, cancel: false)
    order.company.with_lock do
      order.reload
      raise ArgumentError, "La entrega ya no admite cambios" unless order.editable?
      if cancel
        DeliveryRunPlanner.remove(company: order.company, delivery_run: order.visit.delivery_run, order_id: order.id) if order.visit
        order.reload.update!(status: :cancelled)
      else
        order.assign_attributes(attributes)
        order.delivery_order_items.select(&:marked_for_destruction?).each do |item|
          item.delivery_item&.destroy!
          item.association(:delivery_item).reset
        end
        order.save!
        DeliveryRunPlanner.synchronize(order) if order.visit
      end
      order
    end
  end
end
