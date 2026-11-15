module Geocoding
  module Config
    module_function

    def integer(key, default, range)
      Integer(ENV.fetch(key, default.to_s)).clamp(range.begin, range.end)
    rescue ArgumentError
      default
    end

    def enabled?(key, default: false)
      ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, default.to_s))
    end

    def bounds
      value = ENV["GEOCODING_BBOX"].to_s
      return if value.blank?
      parts = value.split(",").map { |item| Float(item) }
      unless parts.size == 4 && parts.all?(&:finite?) && parts[0].between?(-180, 180) && parts[2].between?(-180, 180) && parts[1].between?(-90, 90) && parts[3].between?(-90, 90) && parts[0] < parts[2] && parts[1] < parts[3]
        raise Error, "El área geográfica configurada es inválida."
      end
      parts
    rescue ArgumentError
      raise Error, "El área geográfica configurada es inválida."
    end

    def gemini?
      enabled?("GEMINI_ENABLED") && ENV["GEMINI_API_KEY"].present?
    end

    def photon_url
      ENV["PHOTON_URL"].presence || "https://photon.komoot.io/api/"
    end

    def public_photon?
      URI(photon_url).host.to_s.downcase.in?(%w[photon.komoot.io photon.komoot.de photon.komoot.net])
    rescue URI::InvalidURIError
      true
    end
  end
end
