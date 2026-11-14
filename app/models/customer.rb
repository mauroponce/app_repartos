class Customer < ApplicationRecord
  belongs_to :company
  has_many :delivery_schedules, dependent: :restrict_with_error
  has_many :visits, dependent: :restrict_with_error
  attr_accessor :location_confirmed

  before_validation :clear_outdated_location

  enum :status, { active: "active", inactive: "inactive" }, validate: true
  normalizes :name, :contact, :phone, :address, :city, with: ->(value) { value.strip }
  normalizes :email, with: ->(value) { value.strip.downcase.presence }

  validates :name, :phone, :address, :city, presence: true
  validates :name, length: { maximum: 90 }
  validates :contact, :phone, :email, :address, :city, length: { maximum: 255 }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
  validates :latitude, presence: true, if: -> { longitude.present? }
  validates :longitude, presence: true, if: -> { latitude.present? }
  validates :latitude, :longitude, presence: true, on: :geocoded

  def located?
    latitude.present? && longitude.present?
  end

  scope :alphabetical, -> { order(Arel.sql('LOWER(customers.name) COLLATE "es-x-icu"'), :id) }
  scope :search, ->(query) {
    pattern = "%#{sanitize_sql_like(query)}%"
    where("customers.name ILIKE :q OR contact ILIKE :q OR city ILIKE :q OR phone ILIKE :q", q: pattern)
  }

  private

  def clear_outdated_location
    return unless persisted? && (will_save_change_to_address? || will_save_change_to_city?)
    return if will_save_change_to_latitude? || will_save_change_to_longitude?
    return if ActiveModel::Type::Boolean.new.cast(location_confirmed)

    self.latitude = nil
    self.longitude = nil
  end
end
