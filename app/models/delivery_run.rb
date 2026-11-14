class DeliveryRun < ApplicationRecord
  include TenantIntegrity
  belongs_to :driver, class_name: "User", optional: true
  has_many :visits, -> { order(:position, :id) }, inverse_of: :delivery_run, dependent: :restrict_with_error
  enum :status, { draft: "draft", assigned: "assigned", in_progress: "in_progress", completed: "completed", cancelled: "cancelled" }, validate: true
  validates :scheduled_date, :name, presence: true
  validates :name, length: { maximum: 255 }
  validates :generation_key, uniqueness: { scope: :company_id }, allow_nil: true
  validate :valid_driver
  validate :generated_date_is_immutable

  private

  def valid_driver
    same_company(:driver)
    errors.add(:driver, "debe tener rol repartidor") if driver && !driver.driver?
    if driver&.inactive? && (new_record? || will_save_change_to_driver_id?)
      errors.add(:driver, "debe estar activo para asignarle un reparto")
    end
  end

  def generated_date_is_immutable
    if persisted? && generation_key.present? && will_save_change_to_scheduled_date?
      errors.add(:scheduled_date, "no se puede cambiar en un reparto generado")
    end
  end
end
