class DeliverySchedule < ApplicationRecord
  include RoutingChangeHooks
  include TenantIntegrity
  after_commit -> { OpportunityRefreshRequest.call(company_id) }, on: %i[create update destroy]
  # Recurring times are local wall-clock values, independent of UTC offsets.
  self.skip_time_zone_conversion_for_attributes = %i[preferred_time window_start window_end]
  WEEKDAYS = { 1 => "Lunes", 2 => "Martes", 3 => "Miércoles", 4 => "Jueves", 5 => "Viernes", 6 => "Sábado", 7 => "Domingo" }.freeze
  belongs_to :customer
  has_many :delivery_schedule_items, -> { order(:position, :id) }, inverse_of: :delivery_schedule, dependent: :destroy
  has_many :delivery_orders, dependent: :restrict_with_error
  has_many :visits, dependent: :restrict_with_error
  accepts_nested_attributes_for :delivery_schedule_items, allow_destroy: true

  validates :weekday, numericality: { only_integer: true }
  validates :weekday, inclusion: { in: WEEKDAYS.keys }
  validates :starts_on, presence: true
  validates :active, inclusion: { in: [ true, false ] }
  validate :coherent_dates_and_times
  validate -> { same_company(:customer) }

  scope :active, -> { where(active: true) }
  scope :applicable_on, ->(date) {
    active.where(weekday: date.cwday).where("starts_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", date, date)
  }

  private

  def coherent_dates_and_times
    errors.add(:ends_on, "no puede ser anterior al inicio") if starts_on && ends_on && ends_on < starts_on
    if window_start || window_end
      errors.add(:preferred_time, "elegí horario puntual o franja horaria") if preferred_time
      errors.add(:window_end, "requiere una franja completa con fin posterior al inicio") unless window_start && window_end && window_end > window_start
    end
  end
end
