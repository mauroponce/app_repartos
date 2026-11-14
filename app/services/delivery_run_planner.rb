class DeliveryRunPlanner
  def self.call(company:, delivery_run:, order_ids:)
    company.with_lock do
      run = delivery_run
      raise ArgumentError, "La hoja pertenece a otra empresa" unless run.company_id == company.id
      run.lock! if run.persisted?
      raise ArgumentError, "La hoja ya no admite planificación" unless run.editable?
      run.save!
      ids = Array(order_ids).reject(&:blank?).map(&:to_s).uniq
      orders = company.delivery_orders.where(id: ids).includes(:delivery_order_items).index_by { |order| order.id.to_s }
      raise ActiveRecord::RecordNotFound unless orders.size == ids.size
      ids.each do |id|
        order = orders.fetch(id)
        next if order.pending? && order.visit&.delivery_run_id == run.id
        raise ArgumentError, "Una entrega ya no está disponible; revisá la selección" unless order.pending? && order.visit_id.nil? && order.scheduled_date == run.scheduled_date
        visit = run.visits.includes(:delivery_orders, :delivery_items).detect do |candidate|
          candidate.plannable? && candidate.delivery_orders.any? && candidate.delivery_orders.all? { |other| other.planning_key == order.planning_key }
        end
        visit ||= run.visits.create!(company: company, customer: order.customer, customer_name: order.customer_name, customer_address: order.customer_address, position: run.visits.maximum(:position).to_i + 1)
        order.update!(visit: visit)
        synchronize(order)
      end
      run
    end
  end

  def self.synchronize(order)
    order.delivery_order_items.each do |item|
      execution = order.visit.delivery_items.find_or_initialize_by(delivery_order_item_id: item.id)
      execution.assign_attributes(company: order.company, product_id: item.product_id, description: item.description, unit: item.unit, planned_quantity: item.quantity)
      execution.copying_schedule_snapshot = true
      execution.save!
    end
  end

  def self.remove(company:, delivery_run:, order_id:)
    company.with_lock do
      run = company.delivery_runs.find(delivery_run.id)
      order = company.delivery_orders.find(order_id)
      raise ArgumentError, "La entrega no se puede quitar de esta hoja" unless order.visit&.delivery_run_id == run.id && order.editable? && run.editable?
      visit = order.visit
      visit.delivery_items.where(delivery_order_item_id: order.delivery_order_items.select(:id)).each(&:destroy!)
      order.update!(visit: nil)
      visit.destroy! if visit.delivery_orders.reload.empty? && visit.delivery_items.reload.empty?
      run.visits.each.with_index(1) { |stop, position| stop.update!(position: position) }
    end
  end
end
