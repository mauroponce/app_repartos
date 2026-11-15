class DeliveryStatusEvent < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  belongs_to :delivery_run, optional: true
  belongs_to :visit, optional: true
  belongs_to :delivery_order, optional: true
  belongs_to :user, optional: true
  validates :to_status, :source, presence: true
  validate -> { [ :delivery_run, :visit, :delivery_order, :user ].each { |name| same_company(name) } }
end
