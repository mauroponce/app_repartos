class GeocodingProviderState < ApplicationRecord
  # Global counters contain no customer information. Reservations are shared by
  # web/worker processes through PostgreSQL, including after a worker restart.
  def self.reserve!(provider, interval:, limit:)
    state = create_or_find_by!(provider: provider)
    state.with_lock do
      now = Time.current
      if state.quota_date != now.utc.to_date
        state.assign_attributes(quota_date: now.utc.to_date, requests: 0, error_count: 0, tokens: 0)
      end
      raise Geocoding::QuotaExceeded, "Se alcanzó la cuota diaria de #{provider}." if state.requests >= limit
      if state.available_at && state.available_at > now
        raise Geocoding::Deferred.new((state.available_at - now).ceil)
      end
      state.update!(available_at: now + interval.seconds, requests: state.requests + 1)
    end
  end
end
