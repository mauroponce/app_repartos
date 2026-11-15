module Geocoding
  class Cache
    def initialize(company_id, provider, version)
      @company_id, @provider, @version = company_id, provider, version
    end

    def key(input)
      # All geographic fields, provider URL/model identity and parser version are
      # part of the key. No result is shared between tenants.
      canonical = input.sort.to_h.transform_values { |value| value.is_a?(String) ? Geocoding::Address.clean(value).downcase : value }
      Digest::SHA256.hexdigest(JSON.generate([ @provider, @version, canonical ]))
    end

    def read(input)
      GeocodingCacheEntry.where(company_id: @company_id, key: key(input)).where("expires_at > ?", Time.current).pick(:payload)
    end

    def write(input, payload, empty: false)
      now = Time.current
      GeocodingCacheEntry.upsert({ company_id: @company_id, key: key(input), payload: payload,
        expires_at: now + (empty ? 1.hour : Config.integer("GEOCODING_CACHE_DAYS", 30, 1..90).days), created_at: now, updated_at: now }, unique_by: [ :company_id, :key ])
      payload
    end
  end
end
