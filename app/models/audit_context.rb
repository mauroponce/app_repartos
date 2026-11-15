class AuditContext < ActiveSupport::CurrentAttributes
  attribute :user, :source, :operation_id
end
