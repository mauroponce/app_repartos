class RouteOptimizationProposal < ApplicationRecord
  include TenantIntegrity
  belongs_to :delivery_run
  belongs_to :requested_by, class_name: "User"
  belongs_to :applied_by, class_name: "User", optional: true
  validates :status, inclusion: { in: %w[queued processing ready failed applied discarded expired] }
  validates :fingerprint, :request_key, :expires_at, presence: true
  validate -> { %i[delivery_run requested_by applied_by].each { |name| same_company(name) } }
  before_destroy { errors.add(:base, "La propuesta conserva su trazabilidad"); throw :abort }
  after_commit :notify_result

  def self.request!(user:, run:, settings: {})
    raise ArgumentError, "Requiere administración o supervisión" unless user.active? && user.manages_customers? && run.company_id == user.company_id
    proposal = nil
    fresh = false
    user.company.with_lock do
      user.reload
      raise ArgumentError, "Requiere administración o supervisión" unless user.active? && user.manages_customers? && user.company_id == run.company_id
      current = user.company.delivery_runs.find(run.id)
      problem = RouteOptimization::Problem.new(current, settings: settings)
      fingerprint = problem.fingerprint
      key = Digest::SHA256.hexdigest([ fingerprint, problem.settings ].to_json)
      scope = current.route_optimization_proposals
      scope.where(status: %w[queued processing ready]).where("expires_at <= ?", Time.current).update_all(status: "expired", updated_at: Time.current)
      proposal = scope.find_by(request_key: key, status: %w[queued processing ready])
      unless proposal
        proposal = scope.create!(company: user.company, requested_by: user, fingerprint: fingerprint, request_key: key, settings: problem.settings, expires_at: 30.minutes.from_now)
        fresh = true
      end
    end
    OptimizeDeliveryRunJob.perform_later(user.company_id, proposal.id) if fresh
    proposal
  end

  def apply!(user:)
    company.with_lock do
      reload.lock!
      user.reload
      raise ArgumentError, "No tenés permiso para aplicar esta propuesta" unless user.active? && user.company_id == company_id && user.manages_customers?
      return self if status == "applied"
      raise ArgumentError, "La propuesta caducó; solicitá un nuevo cálculo" if expires_at <= Time.current
      raise ArgumentError, "La propuesta todavía no está lista o no es viable" unless status == "ready" && result.dig("proposed", "feasible") == true
      current = company.delivery_runs.find(delivery_run_id)
      lock_location_inputs(current)
      problem = RouteOptimization::Problem.new(current, settings: settings)
      raise ArgumentError, "La hoja cambió desde el cálculo; solicitá otra propuesta" unless problem.fingerprint == fingerprint
      ids = result.fetch("proposed").fetch("visit_ids")
      unless auto_publish?
        company.route_publications.find_by(delivery_run_id: current.id)&.use_manual!
      end
      Current.set(applying_route_optimization: true) do
        DeliveryRunReorderer.call(company: company, delivery_run: current, visit_ids: ids)
      end
      update!(status: "applied", applied_by: user, applied_at: Time.current)
    end
    self
  end

  def publish_if_current!
    company.with_lock do
      publication = company.route_publications.find_by(proposal_id: id, state: "pending")
      return unless publication
      current = company.delivery_runs.find(delivery_run_id)
      lock_location_inputs(current)
      problem = RouteOptimization::Problem.new(current, settings: settings)
      raise ArgumentError, "La planificación cambió; se requiere una nueva optimización" unless publication.input_key == problem.calculation_key
      raise ArgumentError, "La propuesta no cumple las ventanas o conexiones viales; revisá la hoja" unless result.dig("proposed", "feasible")
      raise ArgumentError, "El repartidor ya no está activo" unless current.driver&.active?
      # Non-routing edits may safely reuse the calculation, with a fresh
      # execution snapshot checked again by apply! under these same locks.
      update!(fingerprint: problem.fingerprint)
      apply!(user: publication.requested_by)
      publication.update!(state: "ready", error_message: nil)
      current.reload.update!(status: :assigned) if current.draft?
    end
  end

  def fail_publication!(message)
    company.route_publications.find_by(proposal_id: id, state: "pending")&.update!(state: "failed", error_message: message.first(1000))
  end

  private

  def lock_location_inputs(run)
    # Customer/schedule editors do not take the planning company mutex. Hold
    # these rows until positions commit so the fingerprint cannot become stale
    # between its check and the reorder. No HTTP work happens under these locks.
    run.lock!
    stops = run.visits.reorder(nil)
    company.customers.where(id: stops.select(:customer_id)).order(:id).lock.load
    company.delivery_schedules.where(id: stops.select(:delivery_schedule_id)).order(:id).lock.load
  end

  def notify_result
    Turbo::StreamsChannel.broadcast_action_to(company, :operations, action: "operations_refresh")
  rescue StandardError => error
    Rails.logger.warn("Route proposal invalidation unavailable: #{error.class.name}")
  end
end
