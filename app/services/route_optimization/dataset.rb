module RouteOptimization
  class Dataset
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
