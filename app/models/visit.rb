class Visit < ApplicationRecord
  include RoutingChangeHooks
  include TenantIntegrity
  include OperationsUpdates
  include StatusAudited
  after_commit -> { OpportunityRefreshRequest.call(company_id) }, if: :saved_change_to_status?
  belongs_to :delivery_run, inverse_of: :visits
  belongs_to :customer
  belongs_to :delivery_schedule, optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true
  has_many :delivery_items, inverse_of: :visit, dependent: :destroy
  has_many :delivery_orders, dependent: :restrict_with_error
  accepts_nested_attributes_for :delivery_items, allow_destroy: true
  enum :status, { pending: "pending", completed: "completed", not_attended: "not_attended", closed: "closed", rescheduled: "rescheduled", rejected: "rejected" }, validate: true
  TIMING_FIELDS = %w[arrived_at unloading_started_at unloading_finished_at].freeze
  validate :validate_timing

  def unloading_seconds
    unloading_finished_at && unloading_started_at && (unloading_finished_at - unloading_started_at).to_i
  end

  def current_customer_location?
    customer.located? && customer_address == [ customer.address, customer.city ].compact.join(", ")
  end

  FAILURE_REASONS = { "shortage" => "Faltante de mercadería", "damaged" => "Mercadería dañada", "customer_request" => "Pedido del cliente", "absent" => "Cliente ausente", "closed" => "Comercio cerrado", "rejected" => "Entrega rechazada", "other" => "Otro motivo" }.freeze
  validates :receipt_version, inclusion: { in: [ 0, 1 ] }
  validates :receiver_name, length: { maximum: 120 }
  validates :failure_reason, inclusion: { in: FAILURE_REASONS.keys }, allow_nil: true
  validates :recorded_at, presence: true, if: -> { receipt_version == 1 && !pending? }
  validates :recorded_latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :recorded_longitude, numericality: { in: -180..180 }, allow_nil: true
  validates :location_accuracy, numericality: { greater_than_or_equal_to: 0, less_than: 100_000_000 }, allow_nil: true
  validate :complete_recorded_location

  before_validation :snapshot_customer, on: :create
  before_validation :set_completion_time
  before_validation :prepare_confirmation
  validates :customer_name, :customer_address, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :delivery_schedule_id, uniqueness: { scope: :delivery_run_id }, allow_nil: true
  validate :tenant_associations
  validate :protect_history
  validate :valid_confirmation
  validate :valid_incident_reason
  after_save :resolve_orders
  after_save -> { RunStockRecorder.record_delivery(self) }, if: -> { saved_change_to_status? && !pending? }
  after_save -> { IncidentRecorder.from_visit(self) }, if: -> { saved_change_to_status? && !pending? }
  before_destroy :protect_destruction

  def plannable?
    pending? && completed_at.nil? && TIMING_FIELDS.all? { |field| public_send(field).nil? } && delivery_items.none? { |item| !item.delivered_quantity.nil? }
  end

  private

  def valid_incident_reason
    return unless receipt_version == 1 && !pending? && (new_record? || status_in_database == "pending")
    partial = completed? && delivery_items.reject(&:marked_for_destruction?).any? { |item| item.delivered_quantity && item.delivered_quantity < item.planned_quantity }
    errors.add(:failure_reason, "es obligatorio para una entrega parcial o fallida") if (partial || !completed?) && failure_reason.blank?
    errors.add(:notes, "describí el motivo de la incidencia") if failure_reason == "other" && notes.blank?
  end

  def validate_timing
    TIMING_FIELDS.each do |field|
      value = public_send(field)
      if persisted? && public_send("#{field}_in_database") && will_save_change_to_attribute?(field)
        errors.add(field, "el horario registrado conserva su historial")
      end
      errors.add(field, "no puede estar en el futuro") if value && value > 5.minutes.from_now
      if persisted? && status_in_database != "pending" && will_save_change_to_attribute?(field)
        errors.add(field, "la visita ya está finalizada")
      end
    end
    if unloading_started_at && (!arrived_at || unloading_started_at < arrived_at)
      errors.add(:unloading_started_at, "requiere llegada previa")
    end
    if unloading_finished_at && (!unloading_started_at || unloading_finished_at < unloading_started_at)
      errors.add(:unloading_finished_at, "requiere inicio previo")
    end
  end

  def complete_recorded_location
    values = [ recorded_latitude, recorded_longitude, location_accuracy, location_captured_at ]
    errors.add(:base, "La ubicación requiere coordenadas, precisión y fecha de captura") if values.any?(&:present?) && values.any?(&:nil?)
  end

  def resolve_orders
    return if pending?
    delivery_orders.pending.find_each { |order| order.update!(status: order.resolved_status) }
  end

  def prepare_confirmation
    return if pending? || (persisted? && status_in_database != "pending")
    self.confirmed_at ||= Time.current if confirmed_by
    unless completed?
      delivery_items.each { |item| item.delivered_quantity = 0 if item.delivered_quantity.nil? }
    end
  end

  def valid_confirmation
    same_company(:confirmed_by)
    if delivery_run&.routing_blocked? && (status_changed? && !pending? || TIMING_FIELDS.any? { |field| will_save_change_to_attribute?(field) })
      errors.add(:base, "Esperá el recorrido definitivo o publicá el orden manual antes de registrar ejecución")
    end
    if pending?
      errors.add(:base, "La visita pendiente no admite confirmación") if confirmed_by_id || confirmed_at
    elsif new_record? || status_in_database == "pending"
      errors.add(:confirmed_by, "debe registrar quién confirma la visita") unless confirmed_by && confirmed_at
      if completed?
        errors.add(:base, "Registrá la cantidad entregada de todos los productos, incluso cero") if delivery_items.reject(&:marked_for_destruction?).any? { |item| item.delivered_quantity.nil? }
      elsif delivery_items.any? { |item| item.delivered_quantity.to_d.positive? }
        errors.add(:base, "Una visita fallida no puede tener mercadería entregada")
      end
    end
  end

  def protect_destruction
    return if plannable?
    errors.add(:base, "La visita ya tiene ejecución registrada")
    throw :abort
  end

  def protect_history
    if delivery_run && persisted? && will_save_change_to_position? && !delivery_run.editable?
      errors.add(:position, "la hoja ya no admite cambios de orden")
    end
    if persisted? && status_in_database != "pending" && (has_changes_to_save? || delivery_items.any?(&:changed_for_autosave?))
      errors.add(:base, "La visita finalizada conserva su ejecución")
    end
    if persisted? && (will_save_change_to_delivery_run_id? || will_save_change_to_customer_id?)
      errors.add(:base, "La visita conserva su hoja y cliente históricos")
    end
    if delivery_run && %w[completed cancelled].include?(delivery_run.status) && (new_record? || has_changes_to_save? || delivery_items.any?(&:changed_for_autosave?))
      errors.add(:base, "La hoja está finalizada")
    end
  end

  def snapshot_customer
    self.company ||= delivery_run&.company
    self.customer_name = customer&.name if customer_name.blank?
    self.customer_address = [ customer&.address, customer&.city ].compact.join(", ") if customer_address.blank?
  end

  def set_completion_time
    self.completed_at ||= Time.current if completed?
  end

  def tenant_associations
    same_company(:delivery_run)
    same_company(:customer)
    same_company(:delivery_schedule)
    if delivery_schedule && delivery_schedule.customer_id != customer_id
      errors.add(:delivery_schedule, "debe corresponder al cliente de la visita")
    end
  end
end
