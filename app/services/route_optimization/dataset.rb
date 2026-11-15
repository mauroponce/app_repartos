module RouteOptimization
  class Dataset
    def self.coverage(url: ENV["OSRM_URL"])
      text = ENV["OSRM_COVERAGE_BBOX"].presence
      manifest = Rails.root.join("storage/routing/current/manifest.json")
      local = URI.parse(url.to_s).host.in?(%w[osrm app-repartos-osrm])
      text ||= JSON.parse(manifest.read).fetch("bbox") if local && manifest.file?
      return unless text
      raise ArgumentError unless text.is_a?(String)
      bounds = text.split(",").map { |value| Float(value) }
      unless bounds.size == 4 && bounds.all?(&:finite?) && bounds.values_at(0, 2).all? { |v| v.between?(-180, 180) } && bounds.values_at(1, 3).all? { |v| v.between?(-90, 90) } && bounds[0] < bounds[2] && bounds[1] < bounds[3]
        raise ArgumentError
      end
      bounds
    rescue JSON::ParserError, KeyError, ArgumentError, Errno::ENOENT
      raise Osrm::Client::Unavailable, "No se pudo verificar la cobertura del mapa activo. La planificación manual sigue disponible."
    end

    def self.validate_coverage!(points, url: ENV["OSRM_URL"])
      bounds = coverage(url: url)
      return unless bounds
      unless points.all? { |longitude, latitude| longitude.between?(bounds[0], bounds[2]) && latitude.between?(bounds[1], bounds[3]) }
        raise Osrm::Client::OutsideCoverage, "Esta ubicación está fuera de la zona disponible para optimización"
      end
    end

    def self.identity
      version = ENV["OSRM_MAP_VERSION"].presence
      manifest = Rails.root.join("storage/routing/current/manifest.json")
      local_provider = URI.parse(ENV["OSRM_URL"].to_s).host.in?(%w[osrm app-repartos-osrm])
      version ||= Digest::SHA256.file(manifest).hexdigest if local_provider && manifest.file?
      # An unversioned external provider must not populate a persistent cache.
      Digest::SHA256.hexdigest([ ENV["OSRM_URL"], "driving", version ].to_json) if version
    rescue URI::InvalidURIError, Errno::ENOENT
      nil
    end
  end
end
