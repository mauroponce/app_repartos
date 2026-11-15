class WorkflowTask < ApplicationRecord
  include TenantIntegrity
  include WorkflowUpdates
  after_commit -> { OpportunityRefreshRequest.call(company_id) }, on: %i[create update]
  CATEGORIES = { "operational" => "Operativa", "commercial" => "Comercial", "administrative" => "Administrativa" }.freeze
  STATUSES = { "pending" => "Pendiente", "in_progress" => "En curso", "completed" => "Completada", "cancelled" => "Cancelada" }.freeze
  belongs_to :creator, class_name: "User", optional: true
  belongs_to :assignee, class_name: "User", optional: true
  belongs_to :customer, optional: true
  belongs_to :delivery_run, optional: true
  belongs_to :delivery_order, optional: true
  belongs_to :visit, optional: true
  belongs_to :incident, optional: true
  belongs_to :commercial_opportunity, optional: true
  has_many :workflow_events, dependent: :restrict_with_error
  validates :title, :source_key, presence: true
  validates :title, length: { maximum: 255 }
  validates :description, :result, length: { maximum: 4000 }
  validates :category, inclusion: { in: CATEGORIES.keys }
  validates :status, inclusion: { in: STATUSES.keys }
  validates :priority, inclusion: { in: Incident::PRIORITIES.keys }
  validates :source_key, uniqueness: { scope: :company_id }
  validate :valid_task
  before_destroy { errors.add(:base, "Las tareas conservan su historial"); throw :abort }
  scope :unfinished, -> { where(status: %w[pending in_progress]) }

  def self.visible_to_driver(user)
    where(company_id: user.company_id, category: "operational").where("workflow_tasks.assignee_id = :user OR (workflow_tasks.assignee_id IS NULL AND workflow_tasks.delivery_run_id IN (SELECT id FROM delivery_runs WHERE company_id = :company AND driver_id = :user))", user: user.id, company: user.company_id)
  end

  def terminal?
    status.in?(%w[completed cancelled])
  end

  private

  def valid_task
    %i[creator assignee customer delivery_run delivery_order incident commercial_opportunity].each { |key| same_company(key) }
    same_company(:visit) if new_record? || visit
    errors.add(:assignee, "debe estar activo") if assignee && !assignee.active?
    errors.add(:assignee, "las tareas internas requieren un administrador o supervisor") if assignee&.driver? && category != "operational"
    errors.add(:category, "una oportunidad genera tareas comerciales internas") if commercial_opportunity && category != "commercial"
    errors.add(:customer, "no coincide con el pedido") if delivery_order && delivery_order.customer_id != customer_id
    errors.add(:customer, "no coincide con la visita") if visit && visit.customer_id != customer_id
    errors.add(:incident, "no coincide con el cliente de la incidencia") if incident && incident.customer_id && incident.customer_id != customer_id
    errors.add(:commercial_opportunity, "no coincide con el cliente de la oportunidad") if commercial_opportunity&.customer_id && commercial_opportunity.customer_id != customer_id
    errors.add(:visit, "no coincide con la ruta") if visit && visit.delivery_run_id != delivery_run_id
    if terminal?
      errors.add(:result, "registrá el resultado o motivo") if result.blank? || closed_at.nil?
    end
    if persisted? && status_in_database.in?(%w[completed cancelled]) && has_changes_to_save?
      errors.add(:base, "La tarea cerrada conserva su historial; creá un seguimiento nuevo")
    end
    if persisted? && (changes_to_save.keys & %w[creator_id source_key incident_id commercial_opportunity_id company_id]).any?
      errors.add(:base, "La tarea conserva su origen")
    end
  end
end
