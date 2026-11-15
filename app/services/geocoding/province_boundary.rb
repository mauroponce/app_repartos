module Geocoding
  class ProvinceBoundary
    class << self
      def names
        features.map { |feature| feature.dig("properties", "nombre") }.sort
      end

      def canonical(name)
        names.find { |candidate| Address.context_key(candidate) == Address.context_key(name) }
      end

      def contains?(province, latitude, longitude)
        return false unless Address.valid_point?(latitude, longitude)
        feature = features.find { |item| Address.context_key(item.dig("properties", "nombre")) == Address.context_key(province) }
        return false unless feature
        geometry = feature.fetch("geometry")
        polygons = geometry.fetch("type") == "Polygon" ? [ geometry.fetch("coordinates") ] : geometry.fetch("coordinates")
        point = [ longitude.to_f, latitude.to_f ]
        polygons.any? do |rings|
          in_ring?(point, rings.first) && rings.drop(1).none? { |ring| in_ring?(point, ring) }
        end
      end

      private

      def features
        @features ||= JSON.parse(File.read(Rails.root.join("config/geocoding/argentina_provinces.geojson"))).fetch("features")
      end

      def in_ring?(point, ring)
        x, y = point
        inside = false
        ring.each_cons(2) do |a, b|
          x1, y1 = a
          x2, y2 = b
          next unless (y1 > y) != (y2 > y)
          crossing = (x2 - x1) * (y - y1) / (y2 - y1) + x1
          inside = !inside if x < crossing
        end
        inside
      end
    end
  end
end
