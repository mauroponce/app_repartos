class DeliveryRun < ApplicationRecord
  include TenantIntegrity
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

  def editable?
    (draft? || assigned?) && visits.includes(:delivery_items).all?(&:plannable?)
  end

  private

  def protect_history
    return unless persisted?
    if %w[completed cancelled].include?(status_in_database) && has_changes_to_save?
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
