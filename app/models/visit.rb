class Visit < ApplicationRecord
  include TenantIntegrity
  belongs_to :delivery_run, inverse_of: :visits
  belongs_to :customer
  belongs_to :delivery_schedule, optional: true
  has_many :delivery_items, inverse_of: :visit, dependent: :destroy
  has_many :delivery_orders, dependent: :restrict_with_error
  accepts_nested_attributes_for :delivery_items, allow_destroy: true
  enum :status, { pending: "pending", completed: "completed", not_attended: "not_attended", closed: "closed", rescheduled: "rescheduled" }, validate: true

  before_validation :snapshot_customer, on: :create
  before_validation :set_completion_time
  validates :customer_name, :customer_address, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :delivery_schedule_id, uniqueness: { scope: :delivery_run_id }, allow_nil: true
  validate :tenant_associations
  validate :protect_history
  after_save :complete_orders
  before_destroy :protect_destruction

  def plannable?
    pending? && completed_at.nil? && delivery_items.none? { |item| !item.delivered_quantity.nil? }
  end

  private

  def complete_orders
    delivery_orders.pending.find_each { |order| order.update!(status: :completed) } if completed?
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
    if completed? && delivery_orders.any? && delivery_items.any? { |item| item.delivered_quantity.nil? }
      errors.add(:base, "Registrá la cantidad entregada de todos los productos, incluso cero")
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
