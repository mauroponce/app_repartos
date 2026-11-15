class Customer < ApplicationRecord
  include RoutingChangeHooks
  belongs_to :company
  after_create_commit -> { OpportunityRefreshRequest.call(company_id) }
  after_update_commit -> { OpportunityRefreshRequest.call(company_id) }, if: :saved_change_to_status?
  has_many :communication_consents, dependent: :restrict_with_error
  has_many :customer_notifications, dependent: :restrict_with_error
  has_many :delivery_orders, dependent: :restrict_with_error
  has_many :delivery_schedules, dependent: :restrict_with_error
  has_many :visits, dependent: :restrict_with_error
  attr_accessor :location_confirmed

  before_validation :clear_outdated_location
  before_validation :confirm_form_location

  enum :status, { active: "active", inactive: "inactive" }, validate: true
  normalizes :name, :contact, :address, :city, with: ->(value) { value.strip }
  normalizes :phone, :external_code, with: ->(value) { value.strip.presence }
  normalizes :email, with: ->(value) { value.strip.downcase.presence }

  validates :name, :address, :city, presence: true
  validates :external_code, length: { maximum: 255 }, uniqueness: { scope: :company_id }, allow_nil: true
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

  def routing_location?
    located? && location_verification.in?(%w[legacy reliable manual]) &&
      (location_verification == "legacy" || Geocoding::ProvinceBoundary.contains?(company.province, latitude, longitude))
  end

  scope :alphabetical, -> { order(Arel.sql('LOWER(customers.name) COLLATE "es-x-icu"'), :id) }
  scope :search, ->(query) {
    pattern = "%#{sanitize_sql_like(query)}%"
    where("customers.name ILIKE :q OR contact ILIKE :q OR city ILIKE :q OR phone ILIKE :q", q: pattern)
  }

  private

  def confirm_form_location
    return unless validation_context == :geocoded
    self.location_verification = located? ? "manual" : "pending"
  end

  def clear_outdated_location
    return unless persisted? && (will_save_change_to_address? || will_save_change_to_city?)
    return if will_save_change_to_latitude? || will_save_change_to_longitude?
    return if ActiveModel::Type::Boolean.new.cast(location_confirmed)

    self.latitude = nil
    self.longitude = nil
    self.location_verification = "pending"
  end
end
