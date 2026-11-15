class RunStockRecorder
  def self.call(user:, run_id:, attributes:)
    user.company.with_lock do
      raise ArgumentError, "La cuenta no puede gestionar carga" unless user.reload.active? && user.manages_customers?
      run = user.company.delivery_runs.find(run_id)
      values = attributes.symbolize_keys
      raise ArgumentError, "Las entregas se registran desde su visita" unless values[:kind].in?(RunStockMovement::KINDS.keys - [ "delivery" ])
      raise ArgumentError, "La hoja cancelada no admite nuevas cargas" if run.cancelled? && values[:kind] == "load"
      id = values.fetch(:operation_id).to_s
      raise ArgumentError, "Identificador inválido" unless id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
      product = user.company.products.find(values[:product_id]) if values[:product_id].present?
      movement = run.run_stock_movements.new(values.slice(:kind, :quantity, :description, :unit, :reason).merge(
        company: user.company, user: user, product: product, operation_id: id, occurred_at: Time.current))
      movement.description = product.name if product && movement.description.blank?
      movement.unit = product.unit if product && movement.unit.blank?
      if (existing = user.company.run_stock_movements.find_by(operation_id: id))
        fields = %w[delivery_run_id user_id product_id kind quantity description unit reason]
        raise ArgumentError, "El identificador ya corresponde a otro movimiento" unless fields.all? { |key| existing[key] == movement[key] }
        return existing
      end
      movement.save!
      movement
    end
  end

  def self.record_delivery(visit)
    return if visit.pending?
    visit.delivery_items.each do |item|
      next unless item.delivered_quantity&.positive?
      next if RunStockMovement.exists?(delivery_item_id: item.id, kind: "delivery")
      visit.delivery_run.run_stock_movements.create!(company: visit.company, user: visit.confirmed_by,
        delivery_item: item, product: item.product, description: item.description, unit: item.unit,
        quantity: item.delivered_quantity, kind: "delivery", operation_id: SecureRandom.uuid,
        occurred_at: visit.recorded_at || visit.confirmed_at || Time.current)
    end
  end
end
