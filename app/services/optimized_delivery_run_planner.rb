class OptimizedDeliveryRunPlanner
  def self.call(company:, token:, name:, status:)
    proposal = DeliveryRouteOptimizer.verifier.verified(token.to_s, purpose: :route_proposal)
    raise ArgumentError, "La propuesta venció o no es válida. Volvé a optimizar." unless proposal && proposal["company_id"] == company.id
    raise ArgumentError, "Elegí borrador o asignada" unless status.in?(%w[draft assigned])
    raise ArgumentError, "Ingresá un nombre de hasta 255 caracteres" unless name.present? && name.length <= 255

    company.with_lock do
      existing = company.delivery_runs.where(optimization_key: proposal.fetch("key")).order(:id).to_a
      return existing if existing.any?
      problem = current_problem(company, proposal)
      raise ArgumentError, "Los pedidos, ubicaciones o repartidores cambiaron. Volvé a optimizar." unless problem.fingerprint == proposal.fetch("fingerprint")
      proposal.fetch("routes").map do |route|
        run = company.delivery_runs.new(name: "#{name} · #{route.fetch('driver_name')}".truncate(255), scheduled_date: problem.date,
          driver_id: route.fetch("driver_id"), status: status, optimization_key: proposal.fetch("key"),
          optimization_data: route.merge("settings" => problem.settings, "calculated_at" => Time.current.iso8601))
        DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: route.fetch("order_ids"))
      end
    end
  end

  def self.current_problem(company, proposal)
    RouteOptimizationProblem.new(company: company, date: proposal.fetch("date"), order_ids: proposal.fetch("order_ids"), settings: proposal.fetch("settings"), lock: true)
  rescue ActiveRecord::RecordNotFound
    raise ArgumentError, "Los pedidos o repartidores cambiaron. Volvé a optimizar."
  end
  private_class_method :current_problem
end
