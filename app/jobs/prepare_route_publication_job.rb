class PrepareRoutePublicationJob < ApplicationJob
  self.enqueue_after_transaction_commit = true
  queue_as :default
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3

  def perform(company_id, run_id)
    company = Company.find_by(id: company_id)
    return unless company
    company.with_lock do
      publication = company.route_publications.find_by(delivery_run_id: run_id, state: "pending")
      return unless publication
      run = company.delivery_runs.find(run_id)
      raise ArgumentError, "La hoja ya tiene ejecución o está finalizada" unless run.editable?
      user = publication.requested_by
      raise ArgumentError, "La cuenta que confirmó ya no tiene permiso" unless user.active? && user.manages_customers?
      problem = RouteOptimization::Problem.new(run, settings: publication.settings)
      key = problem.calculation_key
      active = publication.proposal
      return if active && active.status.in?(%w[queued processing]) && active.expires_at > Time.current && publication.input_key == key
      proposal = RouteOptimizationProposal.request!(user: user, run: run, settings: publication.settings)
      proposal.update!(auto_publish: true)
      publication.update!(proposal: proposal, input_key: key, error_message: nil)
      OptimizeDeliveryRunJob.perform_later(company_id, proposal.id) if proposal.status == "ready"
    end
  rescue Osrm::Client::Error, ArgumentError, ActiveRecord::RecordInvalid => error
    company&.with_lock do
      company.route_publications.find_by(delivery_run_id: run_id, state: "pending")&.update!(state: "failed", error_message: error.message.first(1000))
    end
  end
end
