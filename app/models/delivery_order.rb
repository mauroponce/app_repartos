class DeliveryOrder < ApplicationRecord
  include TenantIntegrity
  self.skip_time_zone_conversion_for_attributes = %i[preferred_time window_start window_end]
  belongs_to :customer
  belongs_to :delivery_schedule, optional: true
  belongs_to :visit, optional: true
  has_one :delivery_run, through: :visit
  has_many :delivery_order_items, -> { order(:position, :id) }, inverse_of: :delivery_order, dependent: :restrict_with_error
  accepts_nested_attributes_for :delivery_order_items, allow_destroy: true
  enum :status, { pending: "pending", completed: "completed", cancelled: "cancelled" }, validate: true

  before_validation :snapshot_customer
  validates :scheduled_date, :customer_name, :customer_address, presence: true
  validates :delivery_schedule_id, uniqueness: { scope: [ :company_id, :scheduled_date ] }, allow_nil: true
  validate :valid_associations_and_times
  validate :has_merchandise
  validate :protect_execution, on: :update
  before_destroy { errors.add(:base, "Las entregas se cancelan para conservar el historial"); throw :abort }

  scope :unplanned, -> { pending.where(visit_id: nil) }

  def planning_key
    [ customer_id, customer_address, preferred_time&.strftime("%H:%M:%S"), window_start&.strftime("%H:%M:%S"), window_end&.strftime("%H:%M:%S") ]
  end

  def editable?
    pending? && (visit.nil? || (visit.plannable? && visit.delivery_run.editable?))
  end

  def display_status
    pending? && visit_id? ? "assigned" : status
  end

  private

  def snapshot_customer
    self.customer_name = customer&.name if customer_name.blank? || (persisted? && will_save_change_to_customer_id?)
    self.customer_address = [ customer&.address, customer&.city ].compact.join(", ") if customer_address.blank? || (persisted? && will_save_change_to_customer_id?)
  end

  def has_merchandise
    errors.add(:delivery_order_items, "debe incluir al menos un producto") unless delivery_order_items.any? { |item| !item.marked_for_destruction? }
  end

  def valid_associations_and_times
    same_company(:customer)
    same_company(:delivery_schedule)
    same_company(:visit)
    errors.add(:delivery_schedule, "debe corresponder al cliente") if delivery_schedule && delivery_schedule.customer_id != customer_id
    if visit
      errors.add(:visit, "debe corresponder al cliente y fecha") unless visit.customer_id == customer_id && visit.delivery_run.scheduled_date == scheduled_date
      if validation_context != :historical_import && pending? && !visit.delivery_run.editable? && will_save_change_to_visit_id?
        errors.add(:visit, "la hoja ya no admite asignaciones")
      end
    end
    if window_start || window_end
      errors.add(:preferred_time, "elegí horario puntual o franja horaria") if preferred_time
      errors.add(:window_end, "requiere una franja completa con fin posterior al inicio") unless window_start && window_end && window_end > window_start
    end
  end

  def protect_execution
    if status_in_database != "pending"
      errors.add(:base, "La entrega finalizada conserva su historial") if has_changes_to_save? || delivery_order_items.any?(&:changed_for_autosave?)
    elsif visit && !visit.plannable? && (changes_to_save.keys - %w[status updated_at]).any?
      errors.add(:base, "La entrega ya tiene ejecución registrada")
    end
    if visit_id_in_database && will_save_change_to_visit_id?
      previous_visit = company.visits.find(visit_id_in_database)
      errors.add(:visit, "conserva su ejecución y no puede trasladarse") unless previous_visit.plannable? && previous_visit.delivery_run.editable?
    end
    if will_save_change_to_status? && cancelled? && visit_id.present?
      errors.add(:status, "quitá primero la entrega de su hoja")
    end
    if visit_id_in_database && (will_save_change_to_customer_id? || will_save_change_to_scheduled_date? || will_save_change_to_preferred_time? || will_save_change_to_window_start? || will_save_change_to_window_end?)
      errors.add(:base, "Quitá la entrega de la hoja antes de cambiar cliente, fecha u horario")
    end
  end
end
