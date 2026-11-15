module Geocoding
  class Photon
    def initialize(company_id:, http: nil)
      @http = http || HttpClient.new(provider: "photon", url: Config.photon_url)
      @cache = Cache.new(company_id, "photon", "parser-1:#{@http.identity}")
    end

    def search(address, alternative: false)
      parts = [ Address.query(address), address["city"], address["district"], address["province"], address["country"] ].compact_blank
      parts[0] = address["query"] if alternative && address["query"].present?
      input = address.slice(*Address::CONTEXT_FIELDS).merge("q" => parts.uniq.join(", "), "bbox" => Config.bounds)
      if (hit = @cache.read(input))
        return hit.fetch("candidates")
      end
      query = { q: input["q"], countrycode: "ar", limit: 8 }
      query[:bbox] = input["bbox"].join(",") if input["bbox"]
      response = @http.call(query: query)
      raise InvalidResponse, "Photon devolvió una respuesta inválida." unless response["features"].is_a?(Array)
      candidates = response["features"].first(8).filter_map { |feature| candidate(feature) }
      @cache.write(input, { "candidates" => candidates }, empty: candidates.empty?)
      candidates
    rescue TypeError, NoMethodError
      raise InvalidResponse, "Photon devolvió una estructura inválida."
    end

    private

    def candidate(feature)
      return unless feature.is_a?(Hash) && feature.dig("geometry", "type") == "Point"
      point, p = feature.dig("geometry", "coordinates"), feature["properties"]
      return unless point.is_a?(Array) && point.size == 2 && p.is_a?(Hash)
      text = ->(key) { p[key].is_a?(String) || p[key].is_a?(Numeric) ? Address.clean(p[key]).first(255).presence : nil }
      country = text.call("countrycode")
      return unless country.to_s.downcase == "ar"
      street, number = text.call("street"), text.call("housenumber")
      city = %w[city town village locality].filter_map { |key| text.call(key) }.first
      subdivision = text.call("district")
      geographic_ambiguity = subdivision.present? && city.present? && Address.context_key(subdivision) != Address.context_key(city)
      kind = text.call("type")
      # A city centroid, a street geometry and an interpolated point cannot
      # establish a house entrance even if the provider echoes a house number.
      extra = p["extra"].is_a?(Hash) ? p["extra"] : {}
      exact = street.present? && number.present? && !kind.in?(%w[street city locality district]) && text.call("osm_key") != "highway" && extra["addr:interpolation"].blank?
      { "provider" => "photon", "street" => street || text.call("name"), "house_number" => number, "city" => city,
        "district" => text.call("county"), "sublocality" => subdivision, "geographic_ambiguity" => geographic_ambiguity, "province" => text.call("state"), "country" => "Argentina",
        "latitude" => point[1], "longitude" => point[0], "label" => [ street, number, city, text.call("state") ].compact_blank.join(" "),
        "type" => exact ? "address" : (kind || "place"), "precision" => exact ? "address" : "unknown" }
    end
  end
end
