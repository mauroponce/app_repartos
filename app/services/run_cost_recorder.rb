class RunCostRecorder
  def self.call(user:, run_id:, attributes:)
    user.company.with_lock do
      authorize!(user)
      run = user.company.delivery_runs.find(run_id)
      attributes = attributes.symbolize_keys
      id = attributes.fetch(:operation_id).to_s
      raise ArgumentError, "Identificador inválido" unless id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
      if (existing = user.company.delivery_run_costs.find_by(operation_id: id))
        expected = attributes.slice(:category, :description, :vehicle_label, :amount, :estimated)
        probe = user.company.delivery_run_costs.new(expected)
        mismatch = expected.keys.any? { |key| probe.public_send(key) != existing.public_send(key) }
        raise ArgumentError, "El identificador ya corresponde a otro costo" if existing.delivery_run_id != run.id || existing.user_id != user.id || mismatch
        return existing
      end
      if run.currency.nil?
        run.currency = user.company.currency
        run.save!(context: :cost_accounting)
      end
      run.delivery_run_costs.create!(attributes.slice(:category, :description, :vehicle_label, :amount, :estimated).merge(
        company: user.company, user: user, currency: run.currency, operation_id: id, incurred_at: Time.current))
    end
  end

  def self.reverse(user:, run_id:, cost_id:)
    user.company.with_lock do
      authorize!(user)
      run = user.company.delivery_runs.find(run_id)
      original = run.delivery_run_costs.find(cost_id)
      return original.reversal if original.reversal
      run.delivery_run_costs.create!(original.attributes.slice("category", "currency", "vehicle_label", "estimated").merge(
        company: user.company, user: user, reversal_of: original, amount: -original.amount,
        operation_id: SecureRandom.uuid, description: "Anulación: #{original.description}".first(255), incurred_at: Time.current))
    end
  end

  def self.close(user:, run_id:)
    user.company.with_lock do
      authorize!(user)
      run = user.company.delivery_runs.find(run_id)
      return run if run.costs_closed_at
      raise ArgumentError, "Finalizá la hoja antes de cerrar sus costos" unless run.completed? || run.cancelled?
      raise ArgumentError, "Resolvé o anulá los costos estimados antes del cierre" if run.delivery_run_costs.where(estimated: true, reversal_of_id: nil).where.missing(:reversal).exists?
      run.assign_attributes(currency: run.currency || user.company.currency, costs_closed_at: Time.current, costs_closed_by: user)
      run.save!(context: :cost_accounting)
      run
    end
  end

  def self.authorize!(user)
    raise ArgumentError, "La cuenta no puede gestionar costos" unless user.reload.active? && user.manages_customers?
  end
  private_class_method :authorize!
end
