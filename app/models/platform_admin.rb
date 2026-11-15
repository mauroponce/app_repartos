class PlatformAdmin < ApplicationRecord
  has_secure_password
  has_many :platform_sessions, dependent: :destroy
  normalizes :email_address, with: ->(value) { value.strip.downcase }
  validates :name, :email_address, presence: true, length: { maximum: 255 }
  validates :email_address, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :password, format: { with: /\A(?=.*[a-zA-Z])(?=.*\d).+\z/, message: "debe incluir letras y números" }, allow_nil: true
  after_update -> { platform_sessions.destroy_all }, if: :saved_change_to_password_digest?
end
