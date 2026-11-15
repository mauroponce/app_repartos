class DeliveryRun < ApplicationRecord
  include RoutingChangeHooks
  has_one :route_publication, dependent: :restrict_with_error
  scope :published_to_driver, -> { where.not(id: RoutePublication.where(state: %w[pending failed]).select(:delivery_run_id)) }
  has_many :route_optimization_proposals, dependent: :restrict_with_error
  validates :routing_origin, inclusion: { in: %w[company open] }
  include TenantIntegrity
  include OperationsUpdates
  include StatusAudited
  belongs_to :costs_closed_by, class_name: "User", optional: true
  has_many :delivery_run_costs, dependent: :restrict_with_error
  has_many :run_stock_movements, dependent: :restrict_with_error
  before_validation -> { self.currency ||= company&.currency }, on: :create
  validates :currency, inclusion: { in: %w[ARS USD EUR] }, allow_nil: true
  validates :vehicle_label, length: { maximum: 255 }
  validate :protect_accounting
  belongs_to :driver, class_name: "User", optional: true
  has_many :visits, -> { order(:position, :id) }, inverse_of: :delivery_run, dependent: :restrict_with_error
  has_many :delivery_orders, through: :visits
  enum :status, { draft: "draft", assigned: "assigned", in_progress: "in_progress", completed: "completed", cancelled: "cancelled" }, validate: true
  validates :scheduled_date, :name, presence: true
  validates :name, length: { maximum: 255 }
  validates :generation_key, uniqueness: { scope: :company_id }, allow_nil: true
  validate :valid_driver
  validate :generated_date_is_immutable
  validate :protect_history
  before_update :advance_assignment_version

  def dispatchable?
    status.in?(%w[draft assigned in_progress])
  end

  def editable?
    (draft? || assigned?) && visits.includes(:delivery_items).all?(&:plannable?)
  end

  def routing_blocked?
    route_publication&.blocked? || false
  end

  private

  def protect_accounting
    same_company(:costs_closed_by)
    if persisted? && currency_in_database && will_save_change_to_currency?
      errors.add(:currency, "la moneda histórica no se puede cambiar")
    end
    if persisted? && costs_closed_at_in_database && (changes_to_save.keys & %w[costs_closed_at costs_closed_by_id]).any?
      errors.add(:base, "El cierre de costos conserva su historial")
    end
    if persisted? && will_save_change_to_vehicle_label? && !editable?
      errors.add(:vehicle_label, "no se puede cambiar una vez iniciada la hoja")
    end
  end

  def advance_assignment_version
    if will_save_change_to_driver_id? || will_save_change_to_scheduled_date? || (will_save_change_to_status? && cancelled?)
      self.assignment_version = assignment_version_in_database + 1
    end
  end

  def protect_history
    if routing_blocked? && status.in?(%w[in_progress completed]) && will_save_change_to_status?
      errors.add(:status, "esperá el recorrido definitivo o publicá el orden manual")
    end
    return unless persisted?
    accounting_only = validation_context == :cost_accounting && (changes_to_save.keys - %w[currency costs_closed_at costs_closed_by_id updated_at]).empty?
    if %w[completed cancelled].include?(status_in_database) && has_changes_to_save? && !accounting_only
      errors.add(:base, "La hoja finalizada conserva su historial")
    end
    if %w[in_progress completed cancelled].include?(status_in_database) && status.in?(%w[draft assigned])
      errors.add(:status, "no puede volver a planificación")
    end
    errors.add(:status, "requiere resolver todas las paradas") if completed? && visits.any?(&:pending?)
    errors.add(:status, "quitá primero las entregas pendientes de la hoja") if cancelled? && delivery_orders.pending.exists?
  end

  def valid_driver
    errors.add(:status, "requiere un repartidor") if assigned? && driver.nil?
    same_company(:driver)
    errors.add(:driver, "debe tener rol repartidor") if driver && !driver.driver?
    if driver&.inactive? && (new_record? || will_save_change_to_driver_id?)
      errors.add(:driver, "debe estar activo para asignarle un reparto")
    end
  end

  def generated_date_is_immutable
    if persisted? && (generation_key.present? || visits.exists?) && will_save_change_to_scheduled_date?
      errors.add(:scheduled_date, "no se puede cambiar en un reparto generado")
    end
  end
end
