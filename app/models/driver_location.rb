class DriverLocation < ApplicationRecord
  include TenantIntegrity
  include OperationsUpdates
  FRESH_FOR = 2.minutes
  belongs_to :user
  validates :user_id, uniqueness: true
  validates :captured_at, presence: true
  validates :latitude, numericality: { in: -90..90 }
  validates :longitude, numericality: { in: -180..180 }
  validates :accuracy, numericality: { greater_than_or_equal_to: 0, less_than: 100_000_000 }
  validate -> { same_company(:user); errors.add(:user, "debe ser repartidor") unless user&.driver? }

  def fresh?
    sharing? && captured_at >= FRESH_FOR.ago && captured_at <= 2.minutes.from_now
  end
end
