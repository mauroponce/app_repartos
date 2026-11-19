class DriverProfile < ApplicationRecord
  include TenantIntegrity
  belongs_to :user, optional: true
  has_many :delivery_schedules, dependent: :restrict_with_error
  has_many :delivery_orders, dependent: :restrict_with_error
  validates :name, presence: true, length: { maximum: 255 }
  validates :name_key, presence: true
  validate -> { same_company(:user) }
end
