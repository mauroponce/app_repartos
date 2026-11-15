class DriverLocation < ApplicationRecord
  include TenantIntegrity
  include OperationsUpdates
  FRESH_FOR = 2.minutes
  def self.retention
    Integer(ENV.fetch("DRIVER_LOCATION_RETENTION_HOURS", "24")).clamp(1, 168).hours
  end
  belongs_to :user
  validates :user_id, uniqueness: true
  validates :captured_at, presence: true
  validates :latitude, numericality: { in: -90..90 }
  validates :longitude, numericality: { in: -180..180 }
  validates :accuracy, numericality: { greater_than_or_equal_to: 0, less_than: 100_000_000 }
  validate -> { same_company(:user); errors.add(:user, "debe ser repartidor") unless user&.driver? }

  def fresh?
    sharing? && user.location_sharing_enabled? && captured_at >= FRESH_FOR.ago && captured_at <= 2.minutes.from_now
  end
end
