class RoutePublication < ApplicationRecord
  include TenantIntegrity
  belongs_to :delivery_run
  belongs_to :requested_by, class_name: "User"
  belongs_to :proposal, class_name: "RouteOptimizationProposal", optional: true
  validates :state, inclusion: { in: %w[pending ready failed manual] }
  validate -> { %i[delivery_run requested_by proposal].each { |name| same_company(name) } }
  validate do
    errors.add(:proposal, "debe pertenecer a la hoja") if proposal && proposal.delivery_run_id != delivery_run_id
  end
  after_commit :notify_change

  def blocked?
    state.in?(%w[pending failed])
  end

  def use_manual!
    if proposal&.status.in?(%w[queued processing ready])
      proposal.update!(status: "discarded", error_message: "Se eligió conservar el orden manual.")
    end
    update!(state: "manual", error_message: nil)
  end

  def self.request!(user:, run:, settings: {})
    publication = nil
    enqueue = false
    user.company.with_lock do
      user.reload
      raise ArgumentError, "Requiere administración o supervisión" unless user.active? && user.manages_customers? && run.company_id == user.company_id
      run = user.company.delivery_runs.find(run.id)
      raise ArgumentError, "La hoja ya tiene ejecución o está finalizada" unless run.editable?
      raise ArgumentError, "Asigná un repartidor activo antes de confirmar" unless run.driver&.active?
      problem = RouteOptimization::Problem.new(run, settings: settings)
      publication = find_or_initialize_by(company: user.company, delivery_run: run)
      key = problem.calculation_key
      unless publication.persisted? && publication.input_key == key && publication.state.in?(%w[pending ready])
        publication.assign_attributes(requested_by: user, settings: settings, input_key: key, state: "pending", proposal: nil, error_message: nil)
        publication.save!
        run.update_columns(assignment_version: run.assignment_version + 1)
      end
      enqueue = publication.state == "pending"
    end
    PrepareRoutePublicationJob.perform_later(user.company_id, run.id) if enqueue
    publication
  end

  def self.use_manual!(user:, run:)
    user.company.with_lock do
      user.reload
      raise ArgumentError, "No tenés permiso para publicar la hoja" unless user.active? && user.manages_customers? && run.company_id == user.company_id
      run = user.company.delivery_runs.find(run.id)
      raise ArgumentError, "La hoja ya tiene ejecución o está finalizada" unless run.editable?
      raise ArgumentError, "Asigná un repartidor activo antes de publicar" unless run.driver&.active?
      find_by(company: user.company, delivery_run: run)&.use_manual!
      run.update!(status: :assigned) if run.draft?
    end
  end

  private

  def notify_change
    Turbo::StreamsChannel.broadcast_action_to(company, :operations, action: "operations_refresh")
  rescue StandardError => error
    Rails.logger.warn("Route publication notification unavailable: #{error.class.name}")
  end
end
