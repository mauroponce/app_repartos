class DeliveryOrder < ApplicationRecord
  include RoutingChangeHooks
  include TenantIntegrity
  after_commit -> { OpportunityRefreshRequest.call(company_id) }, on: %i[create update destroy]
  include OperationsUpdates
  include StatusAudited
  self.skip_time_zone_conversion_for_attributes = %i[preferred_time window_start window_end]
  belongs_to :customer
  belongs_to :driver_profile, optional: true
  belongs_to :delivery_schedule, optional: true
  belongs_to :visit, optional: true
  belongs_to :rescheduled_from, class_name: "DeliveryOrder", optional: true
  has_one :rescheduled_order, class_name: "DeliveryOrder", foreign_key: :rescheduled_from_id, inverse_of: :rescheduled_from, dependent: :restrict_with_error
  has_one :delivery_run, through: :visit
  has_many :delivery_order_items, -> { order(:position, :id) }, inverse_of: :delivery_order, dependent: :restrict_with_error
  accepts_nested_attributes_for :delivery_order_items, allow_destroy: true
  enum :status, { pending: "pending", completed: "completed", needs_attention: "needs_attention", cancelled: "cancelled" }, validate: true

  before_validation :snapshot_customer
  validates :scheduled_date, :customer_name, :customer_address, presence: true
  validates :load_units, numericality: { only_integer: true, in: 1..1_000_000 }
  validates :service_minutes, numericality: { only_integer: true, in: 0..1440 }
  validates :delivery_schedule_id, uniqueness: { scope: [ :company_id, :scheduled_date ] }, allow_nil: true
  validates :rescheduled_from_id, uniqueness: true, allow_nil: true
  validate :valid_associations_and_times
  validate :has_merchandise
  validate :protect_execution, on: :update
  validate :valid_reschedule
  validate :valid_fulfillment_transition
  before_destroy { errors.add(:base, "Las entregas se cancelan para conservar el historial"); throw :abort }

  scope :unplanned, -> { pending.where(visit_id: nil) }
  scope :requiring_intervention, -> { needs_attention.where.missing(:rescheduled_order) }

  # Calculated from each order line's own execution; surplus on one product
  # never offsets a shortage on another. NULL means unknown, never zero.
  def fulfillment_result
    return "unrecorded" if (pending? || cancelled?) && (visit.nil? || visit.pending?)
    items = delivery_order_items.includes(:delivery_item).to_a
    return "unknown" if items.empty? || items.any? { |item| item.remaining_quantity.nil? || item.delivery_item.visit_id != visit_id }
    return "full" if items.all? { |item| item.remaining_quantity.zero? }
    items.all? { |item| item.delivery_item.delivered_quantity.zero? } ? "none" : "partial"
  end

  def closed?
    completed? || needs_attention?
  end

  def fully_delivered?
    completed? && fulfillment_result == "full"
  end

  def resolved_status
    visit&.completed? && fulfillment_result == "full" ? "completed" : "needs_attention"
  end

  def reschedulable?
    needs_attention? && visit && !visit.pending? && %w[partial none].include?(fulfillment_result)
  end

  def planning_key
    [ customer_id, customer_address, preferred_time&.strftime("%H:%M:%S"), window_start&.strftime("%H:%M:%S"), window_end&.strftime("%H:%M:%S") ]
  end

  def editable?
    pending? && (visit.nil? || (visit.plannable? && visit.delivery_run.editable?))
  end

  def display_status
    return "rescheduled" if needs_attention? && rescheduled_order
    pending? && visit_id? ? "assigned" : status
  end

  private

  def valid_fulfillment_transition
    return if validation_context == :historical_import || !will_save_change_to_status?
    if completed? || needs_attention?
      errors.add(:status, "debe reflejar las cantidades de una visita finalizada") unless visit && !visit.pending? && status == resolved_status
    end
  end

  def valid_reschedule
    same_company(:rescheduled_from)
    if persisted? && will_save_change_to_rescheduled_from_id?
      errors.add(:rescheduled_from, "conserva su vínculo histórico")
    end
    return unless rescheduled_from
    errors.add(:rescheduled_from, "debe corresponder al cliente") unless rescheduled_from.customer_id == customer_id
    errors.add(:rescheduled_from, "no admite reprogramación") if new_record? && !rescheduled_from.reschedulable?
    errors.add(:scheduled_date, "debe ser posterior a la entrega original") unless scheduled_date && scheduled_date > rescheduled_from.scheduled_date
    errors.add(:delivery_schedule, "la reprogramación es una entrega puntual") if delivery_schedule_id
  end

  def snapshot_customer
    self.customer_name = customer&.name if customer_name.blank? || (persisted? && will_save_change_to_customer_id?)
    self.customer_address = [ customer&.address, customer&.city ].compact.join(", ") if customer_address.blank? || (persisted? && will_save_change_to_customer_id?)
  end

  def has_merchandise
    errors.add(:delivery_order_items, "debe incluir al menos un producto") unless delivery_order_items.any? { |item| !item.marked_for_destruction? }
  end

  def valid_associations_and_times
    same_company(:customer)
    same_company(:driver_profile)
    same_company(:delivery_schedule)
    same_company(:visit)
    errors.add(:delivery_schedule, "debe corresponder al cliente") if delivery_schedule && delivery_schedule.customer_id != customer_id
    if visit
      errors.add(:visit, "debe corresponder al cliente y fecha") unless visit.customer_id == customer_id && visit.delivery_run.scheduled_date == scheduled_date
      if validation_context != :historical_import && pending? && !visit.delivery_run.editable? && !(validation_context == :dispatch && visit.plannable? && visit.delivery_run.dispatchable?) && will_save_change_to_visit_id?
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
      errors.add(:visit, "conserva su ejecución y no puede trasladarse") unless previous_visit.plannable? && (previous_visit.delivery_run.editable? || (validation_context == :dispatch && previous_visit.delivery_run.dispatchable?))
    end
    if will_save_change_to_status? && cancelled? && visit_id.present?
      errors.add(:status, "quitá primero la entrega de su hoja")
    end
    if visit_id_in_database && (will_save_change_to_customer_id? || will_save_change_to_scheduled_date? || will_save_change_to_preferred_time? || will_save_change_to_window_start? || will_save_change_to_window_end?)
      errors.add(:base, "Quitá la entrega de la hoja antes de cambiar cliente, fecha u horario")
    end
  end
end
