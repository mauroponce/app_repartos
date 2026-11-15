class WorkflowCommand < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  belongs_to :user
  validates :operation_id, format: { with: DeliveryEvidence::UUID }
  validates :payload_digest, presence: true
  validates :operation_id, uniqueness: { scope: :company_id }
  validate -> { same_company(:user) }
end
