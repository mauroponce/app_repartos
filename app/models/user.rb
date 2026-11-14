class User < ApplicationRecord
  has_secure_password
  belongs_to :company
  has_many :delivery_runs, foreign_key: :driver_id, inverse_of: :driver, dependent: :restrict_with_error
  has_many :sessions, dependent: :destroy

  enum :role, { administrator: "administrator", supervisor: "supervisor", driver: "driver" }, validate: true
  enum :status, { active: "active", inactive: "inactive" }, validate: true
  normalizes :name, with: ->(value) { value.strip }
  normalizes :phone, with: ->(value) { value.strip.presence }
  validates :name, :email_address, presence: true
  validates :name, :email_address, :phone, length: { maximum: 255 }
  validates :email_address, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, allow_nil: true

  scope :alphabetical, -> { order(Arel.sql('LOWER(users.name) COLLATE "es-x-icu"'), :id) }
  scope :search, ->(query) {
    pattern = "%#{sanitize_sql_like(query)}%"
    where("users.name ILIKE :q OR email_address ILIKE :q OR phone ILIKE :q", q: pattern)
  }

  after_update :revoke_sessions, if: -> { (saved_change_to_status? && inactive?) || saved_change_to_password_digest? }

  def manages_customers?
    administrator? || supervisor?
  end

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  private

  def revoke_sessions
    sessions.destroy_all
  end
end
