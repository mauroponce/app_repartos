class OperationsDispatch
  def self.revision(order)
    Digest::SHA256.hexdigest([ order.attributes.slice("id", "status", "visit_id", "scheduled_date", "updated_at"),
      order.visit && DriverWorkSnapshot.revision(order.visit) ].to_json)
  end

  def self.call(user:, order_id:, target_run_id:, date:, revision:, reason:)
    user.company.with_lock do
      raise ArgumentError, "La cuenta no puede gestionar entregas" unless user.reload.active? && user.manages_customers?
      company = user.company
      order = company.delivery_orders.find(order_id)
      raise ArgumentError, "La entrega cambió; actualizá el centro de operaciones" unless revision.present? && revision == self.revision(order)
      source = order.visit
      source_run = source&.delivery_run
      unless order.pending? && (!source || (source.plannable? && source_run.dispatchable?))
        raise ArgumentError, "La entrega ya tiene ejecución registrada"
      end
      date = Date.iso8601(date.to_s)
      raise ArgumentError, "Elegí hoy o una fecha posterior" if date < company.local_date
      target = company.delivery_runs.find(target_run_id) if target_run_id.present?
      if target && (!target.status.in?(%w[assigned in_progress]) || !target.driver&.active? || target.scheduled_date != date)
        raise ArgumentError, "La hoja destino debe estar activa, tener repartidor y coincidir con la fecha"
      end
      raise ArgumentError, "Elegí otra hoja o una nueva fecha" if target && source_run&.id == target.id
      raise ArgumentError, "El pedido ya está sin asignar en esa fecha" if source.nil? && target.nil? && order.scheduled_date == date
      audit = company.delivery_dispatch_changes.new(user: user, delivery_order: order, reason: reason.to_s.strip,
        before_data: state(order))
      audit.valid? || raise(ActiveRecord::RecordInvalid, audit)

      # Remove only this pending order's execution snapshots. Other grouped
      # orders and completed stops retain their identities and quantities.
      source&.delivery_items&.where(delivery_order_item_id: order.delivery_order_items.select(:id))&.each(&:destroy!)
      order.visit = nil
      order.save!(context: :dispatch)
      order.scheduled_date = date
      order.save!
      source.destroy! if source && source.delivery_orders.reload.empty? && source.delivery_items.reload.empty?
      if target
        stop = target.visits.create!(company: company, customer: order.customer, customer_name: order.customer_name,
          customer_address: order.customer_address, position: target.visits.maximum(:position).to_i + 1)
        order.visit = stop
        order.save!(context: :dispatch)
        order.delivery_order_items.each do |item|
          execution = stop.delivery_items.build(company: company, delivery_order_item: item,
            product_id: item.product_id, description: item.description, unit: item.unit, planned_quantity: item.quantity)
          execution.preserve_commercial_snapshot = true
          execution.copying_schedule_snapshot = true
          execution.save!(context: :dispatch)
        end
      end
      [ source_run, target ].compact.uniq(&:id).each do |run|
        run.association(:visits).reset
        run.optimization_data = {}
        run.status = :completed if run.in_progress? && !run.visits.pending.exists?
        run.save!
        run.touch
      end
      audit.after_data = state(order)
      audit.save!
      order
    end
  end

  def self.state(order)
    { date: order.scheduled_date.iso8601, visit_id: order.visit_id, run_id: order.visit&.delivery_run_id,
      driver_id: order.visit&.delivery_run&.driver_id }
  end
  private_class_method :state
end
