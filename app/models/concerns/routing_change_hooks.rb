module RoutingChangeHooks
  extend ActiveSupport::Concern
  included do
    before_save :invalidate_confirmed_routing
    before_destroy :invalidate_destroyed_routing, prepend: true
    after_commit :schedule_confirmed_routing
    after_rollback -> { @invalidated_route_ids = nil }
  end

  private

  def invalidate_confirmed_routing
    @invalidated_route_ids = Array(@invalidated_route_ids) | RouteOptimization::Invalidation.call(self)
  end

  def invalidate_destroyed_routing
    @invalidated_route_ids = Array(@invalidated_route_ids) | RouteOptimization::Invalidation.call(self, destroying: true)
  end

  def schedule_confirmed_routing
    ids, @invalidated_route_ids = @invalidated_route_ids, nil
    Array(ids).each do |id|
      PrepareRoutePublicationJob.perform_later(is_a?(Company) ? self.id : company_id, id)
    rescue StandardError => error
      # Publication stays blocked. Scheduled maintenance recovers the enqueue.
      Rails.logger.warn("Route preparation enqueue unavailable: #{error.class.name}")
    end
  end
end
