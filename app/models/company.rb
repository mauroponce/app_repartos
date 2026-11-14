class Company < ApplicationRecord
  has_many :users, dependent: :restrict_with_error
  has_many :customers, dependent: :restrict_with_error

  has_many :products, dependent: :restrict_with_error
  has_many :delivery_schedules, dependent: :restrict_with_error
  has_many :delivery_runs, dependent: :restrict_with_error
  has_many :visits, dependent: :restrict_with_error
  has_many :product_imports, dependent: :destroy
  normalizes :slug, with: ->(slug) { slug.strip.downcase }
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :time_zone, presence: true
  validate :valid_time_zone

  def local_date
    Time.current.in_time_zone(time_zone).to_date
  end

  private

  def valid_time_zone
    errors.add(:time_zone, "no es válida") unless ActiveSupport::TimeZone[time_zone]
  end
end
