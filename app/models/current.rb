class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :platform_session
  attribute :applying_route_optimization
  attribute :driver_work_revision
  delegate :user, to: :session, allow_nil: true
  delegate :company, to: :user, allow_nil: true
end
