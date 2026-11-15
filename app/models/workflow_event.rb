class WorkflowEvent < ApplicationRecord
  include TenantIntegrity
  include ImmutableRecord
  belongs_to :user, optional: true
  belongs_to :incident, optional: true
  belongs_to :workflow_task, optional: true
  belongs_to :commercial_opportunity, optional: true
  validates :action, presence: true
  validates :message, length: { maximum: 4000 }
  validate -> { %i[user incident workflow_task commercial_opportunity].each { |key| same_company(key) } }
end
