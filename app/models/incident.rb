class Incident < ApplicationRecord
  include TenantIntegrity
  include WorkflowUpdates
  KINDS = { "closed" => "Cliente cerrado", "absent" => "Cliente ausente o no atiende", "rejected" => "Cliente rechaza mercadería", "shortage" => "Mercadería faltante", "damaged" => "Mercadería dañada", "address" => "Dirección incorrecta", "vehicle" => "Problema con el vehículo", "other" => "Otro" }.freeze
  STATUSES = { "open" => "Abierta", "needs_decision" => "Requiere decisión", "follow_up" => "En seguimiento", "resolved" => "Resuelta", "dismissed" => "Descartada" }.freeze
  PRIORITIES = { "low" => "Baja", "normal" => "Normal", "high" => "Alta", "urgent" => "Urgente" }.freeze
  belongs_to :reporter, class_name: "User", optional: true
  belongs_to :driver, class_name: "User", optional: true
  belongs_to :assigned_to, class_name: "User", optional: true
  belongs_to :delivery_run, optional: true
  belongs_to :visit, optional: true
  belongs_to :customer, optional: true
  has_many :incident_photos, dependent: :restrict_with_error
  has_many :workflow_tasks, dependent: :restrict_with_error
  has_many :workflow_events, dependent: :restrict_with_error
  validates :kind, inclusion: { in: KINDS.keys }
  validates :status, inclusion: { in: STATUSES.keys }
  validates :priority, inclusion: { in: PRIORITIES.keys }
  validates :source, inclusion: { in: %w[manual automatic] }
  validates :description, :source_key, presence: true
  validates :description, length: { maximum: 4000 }
  validates :resolution, length: { maximum: 4000 }
  validates :source_key, uniqueness: { scope: :company_id }
  validate :consistent_context
  before_destroy { errors.add(:base, "Las incidencias conservan su historial"); throw :abort }
  scope :unresolved, -> { where(status: %w[open needs_decision follow_up]) }
  scope :visible_to_driver, ->(user) { where(company_id: user.company_id).where("reporter_id = :id OR driver_id = :id", id: user.id) }

  def terminal?
    status.in?(%w[resolved dismissed])
  end

  def overdue?
    !terminal? && due_at && due_at < Time.current
  end

  private

  def consistent_context
    %i[reporter driver assigned_to delivery_run customer].each { |key| same_company(key) }
    errors.add(:driver, "debe ser repartidor") if driver && !driver.driver?
    same_company(:visit) if new_record? || visit
    errors.add(:visit, "no corresponde a la ruta o cliente") if visit && (visit.delivery_run_id != delivery_run_id || visit.customer_id != customer_id)
    errors.add(:assigned_to, "debe ser administrador o supervisor activo") if assigned_to && (!assigned_to.active? || !assigned_to.manages_customers?)
    if terminal?
      errors.add(:resolution, "indicá el motivo del cierre") if resolution.blank? || resolved_at.nil?
    end
    if persisted?
      protected_fields = %w[reporter_id driver_id delivery_run_id visit_id customer_id source source_key context occurred_at kind description]
      errors.add(:base, "El reporte original se conserva; agregá una acción de seguimiento") if (changes_to_save.keys & protected_fields).any?
      errors.add(:base, "La incidencia cerrada conserva su historial") if status_in_database.in?(%w[resolved dismissed]) && has_changes_to_save?
    end
  end
end
