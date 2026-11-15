module Geocoding
  class Address
    CONTEXT_FIELDS = %w[city district province postal_code country].freeze
    class << self
      def clean(value)
        value.to_s.gsub(/[[:cntrl:]]/, " ").gsub(/[[:space:]]+/, " ").strip.first(1000)
      end

      def fold(value)
        ActiveSupport::Inflector.transliterate(clean(value)).downcase.gsub(/[^a-z0-9 ]/, " ").squish
      end

      def street_key(value)
        fold(value).gsub(/\b(?:avenida|avda|av|calle|cal|pje|pasaje)\b/, " ").gsub(/\birigoyen\b/, "yrigoyen").squish
      end

      def context_key(value)
        text = fold(value)
        { "caba" => "ciudad autonoma de buenos aires", "capital federal" => "ciudad autonoma de buenos aires", "bs as" => "buenos aires", "bsas" => "buenos aires", "pba" => "buenos aires", "provincia de buenos aires" => "buenos aires" }.fetch(text, text)
      end

      def normalize(data, context = {})
        source = clean(data["address"])
        text = source.gsub(/\b(?:avda|av)\.?\s+/i, "Avenida ").gsub(/\besq\.?\s+/i, "y ")
        parts = text.split(/\s*[,;]\s*/)
        result = { "original" => source, "query" => text, "country" => "Argentina", "house_number_approximate" => false,
          "intersection" => nil, "between" => [], "references" => [], "missing_information" => [], "ambiguities" => [] }
        CONTEXT_FIELDS.each { |field| result[field] = clean(data[field].presence || context[field]).presence if data[field].present? || context[field].present? }
        result["street"] = parts.first.to_s
        unless fold(text).match?(/\b(?:ruta|km|kilometro)\b/)
          match = parts.first.to_s.match(/\A(.+?)\s+(al\s+)?(\d{1,6})(?!\d)(?:\s+(?!de\b)(.+)|\s*)\z/i)
          if match
            result["street"] = match[1]
            result["house_number"] = match[3]
            result["house_number_approximate"] = match[2].present?
            tail = clean(match[4])
            if tail.present? && !fold(tail).match?(/\A(?:a |cerca|frente|entre|a dos|detras|referencia)/)
              if result["city"].present? && context_key(result["city"]) != context_key(tail)
                result["ambiguities"] << "La localidad del texto difiere del contexto indicado."
              end
              result["city"] ||= tail
            elsif tail.present?
              result["references"] << tail
            end
          end
        end
        result["city"] ||= parts[1] if parts[1].present? && !fold(parts[1]).match?(/\A(?:cerca|frente|entre|a )/)
        if result["street"].match?(/\s+y\s+/i)
          result["intersection"] = result["street"].split(/\s+y\s+/i, 2).last
          result["street"] = result["street"].split(/\s+y\s+/i, 2).first
        end
        if text.match?(/\bentre\b/i)
          result["between"] = text.split(/\bentre\b/i, 2).last.split(/\s+y\s+/i).first(2)
        end
        result["missing_information"] << "localidad" if result["city"].blank?
        result["missing_information"] << "altura" if result["house_number"].blank? && result["intersection"].blank?
        result["geocodable"] = source.size >= 4
        result
      end

      def query(address)
        street = [ address["street"], address["house_number"] ].compact_blank.join(" ")
        street += " y #{address['intersection']}" if address["intersection"].present?
        street.presence || address["query"]
      end

      def valid_point?(latitude, longitude, country: nil)
        lat, lon = Float(latitude), Float(longitude)
        return false unless lat.finite? && lon.finite? && lat.between?(-90, 90) && lon.between?(-180, 180)
        return lat.between?(-56, -21) && lon.between?(-74, -53) if context_key(country).in?(%w[argentina ar])
        true
      rescue ArgumentError, TypeError
        false
      end

      def distance(a, b)
        lat1, lat2 = [ a["latitude"], b["latitude"] ].map { |v| v.to_f * Math::PI / 180 }
        delta_lat = lat2 - lat1
        delta_lon = (b["longitude"].to_f - a["longitude"].to_f) * Math::PI / 180
        arc = Math.sin(delta_lat / 2)**2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(delta_lon / 2)**2
        6_371_000 * 2 * Math.asin(Math.sqrt(arc.clamp(0, 1)))
      end
    end
  end
end
