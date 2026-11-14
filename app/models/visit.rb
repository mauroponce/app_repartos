class Visit < ApplicationRecord
  include TenantIntegrity
  belongs_to :delivery_run, inverse_of: :visits
  belongs_to :customer
  belongs_to :delivery_schedule, optional: true
  has_many :delivery_items, inverse_of: :visit, dependent: :destroy
  accepts_nested_attributes_for :delivery_items, allow_destroy: true
  enum :status, { pending: "pending", completed: "completed", not_attended: "not_attended", closed: "closed", rescheduled: "rescheduled" }, validate: true

  before_validation :snapshot_customer, on: :create
  before_validation :set_completion_time
  validates :customer_name, :customer_address, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :delivery_schedule_id, uniqueness: { scope: :delivery_run_id }, allow_nil: true
  validate :tenant_associations

  private

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
