class OptimizeDeliveryRunJob < ApplicationJob
  self.enqueue_after_transaction_commit = true
  queue_as :routing
  limits_concurrency to: 1, key: ->(_company_id, _proposal_id) { "route-optimization" }, duration: 5.minutes
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3

  def perform(company_id, proposal_id)
    company = Company.find_by(id: company_id)
    return unless company
    proposal = company.route_optimization_proposals.find_by(id: proposal_id)
    return unless proposal
    problem = nil
    company.with_lock do
      proposal.reload
      if proposal.status == "ready" && proposal.auto_publish?
        proposal.publish_if_current!
        return
      end
      return unless proposal.status.in?(%w[queued processing])
      if proposal.auto_publish?
        publication = company.route_publications.find_by(proposal_id: proposal.id, state: "pending")
        return unless publication
      end
      if proposal.expires_at <= Time.current
        proposal.update!(status: "expired")
        proposal.fail_publication!("El cálculo venció antes de publicarse. Volvé a confirmar la hoja.")
        return
      end
      problem = RouteOptimization::Problem.new(company.delivery_runs.find(proposal.delivery_run_id), settings: proposal.settings)
      unchanged = proposal.auto_publish? ? publication.input_key == problem.calculation_key : proposal.fingerprint == problem.fingerprint
      raise ArgumentError, "La hoja cambió antes del cálculo; solicitá una nueva propuesta" unless unchanged
      proposal.update!(status: "processing", error_message: nil)
    end
    result = Time.use_zone(company.time_zone) { problem.calculate }
    company.with_lock do
      proposal.reload
      return unless proposal.status == "processing"
      current = RouteOptimization::Problem.new(company.delivery_runs.find(proposal.delivery_run_id), settings: proposal.settings)
      if proposal.auto_publish?
        publication = company.route_publications.find_by(proposal_id: proposal.id, state: "pending")
        return unless publication
        unchanged = publication.input_key == current.calculation_key
      else
        unchanged = proposal.fingerprint == current.fingerprint
      end
      raise ArgumentError, "La hoja cambió durante el cálculo; solicitá una nueva propuesta" unless unchanged
      proposal.update!(status: proposal.expires_at <= Time.current ? "expired" : "ready", result: result)
      proposal.publish_if_current! if proposal.auto_publish? && proposal.status == "ready"
      proposal.fail_publication!("El cálculo venció antes de publicarse. Volvé a confirmar la hoja.") if proposal.status == "expired"
    end
  rescue Osrm::Client::Error, ArgumentError, ActiveRecord::RecordInvalid => error
    company&.with_lock do
      proposal&.reload
      proposal.update!(status: "failed", error_message: error.message.first(1000)) if proposal&.status.in?(%w[queued processing])
      proposal&.fail_publication!(error.message)
    end
  end
end
