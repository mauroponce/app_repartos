class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :applying_route_optimization
  delegate :user, to: :session, allow_nil: true
  delegate :company, to: :user, allow_nil: true
end
