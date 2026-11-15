module Geocoding
  class Evaluator
    def call(address, candidates)
      evaluated = candidates.first(50).map { |candidate| evaluate(address, candidate) }
      plausible = evaluated.select { |candidate| candidate["rejections"].empty? }.sort_by { |candidate| [ -candidate["score"], candidate["precision"] == "address" ? 0 : 1 ] }
      best = plausible.first
      return result("unlocated", nil, evaluated) unless best
      radius = Config.integer("GEOCODING_AGREEMENT_METERS", 150, 10..1000)
      rivals = plausible.drop(1).select { |candidate| (best["score"] - candidate["score"]).abs <= 15 && Address.distance(best, candidate) > radius }
      if rivals.any? || best["truncated"] || best["geographic_ambiguity"] || address["ambiguities"].present?
        return result("ambiguous", best, evaluated)
      end
      complete = address["house_number"].present? && address["city"].present? && !address["house_number_approximate"] && address["between"].blank? && address["intersection"].blank?
      threshold = Config.integer("GEOCODING_RELIABLE_SCORE", 90, 90..100)
      reliable = complete && best["score"] >= threshold && best["precision"] == "address" && best["type"] == "address" && !best["interpreted"]
      result(reliable ? "reliable" : "approximate", best, evaluated)
    end

    private

    def evaluate(address, candidate)
      result = candidate.deep_dup
      reasons, score = [], 0
      reasons << "Coordenadas ausentes o fuera del país" unless Address.valid_point?(candidate["latitude"], candidate["longitude"], country: address["country"])
      if Address.street_key(address["street"]) == Address.street_key(candidate["street"]) && address["street"].present?
        score += 35
      else
        reasons << "La calle no coincide"
      end
      if address["house_number"].present?
        candidate["house_number"].to_s == address["house_number"].to_s ? score += 30 : reasons << "La altura no coincide"
      end
      %w[city district province].each do |field|
        next if address[field].blank?
        if Address.context_key(address[field]) == Address.context_key(candidate[field])
          score += { "city" => 25, "district" => 5, "province" => 5 }.fetch(field)
        else
          reasons << "No coincide #{ { "city" => "la localidad", "district" => "el partido/departamento", "province" => "la provincia" }.fetch(field)}"
        end
      end
      if address["province"].present? && !ProvinceBoundary.contains?(address["province"], candidate["latitude"], candidate["longitude"])
        reasons << "Las coordenadas no pertenecen a la provincia indicada"
      end
      if (bounds = Config.bounds) && Address.valid_point?(candidate["latitude"], candidate["longitude"])
        unless candidate["longitude"].to_f.between?(bounds[0], bounds[2]) && candidate["latitude"].to_f.between?(bounds[1], bounds[3])
          reasons << "Fuera del área geográfica configurada"
        end
      end
      score += 5 if address["province"].blank? && candidate["province"].present?
      score += 5 if address["district"].blank? && candidate["district"].present?
      if address["intersection"].present? && Address.street_key(address["intersection"]) != Address.street_key(candidate["intersection"])
        reasons << "La intersección no coincide"
      end
      if address["expected_latitude"] && address["expected_longitude"] && Address.valid_point?(candidate["latitude"], candidate["longitude"])
        expected = { "latitude" => address["expected_latitude"], "longitude" => address["expected_longitude"] }
        max_distance = Config.integer("GEOCODING_EXPECTED_RADIUS_KM", 50, 1..500) * 1000
        reasons << "Fuera de la zona esperada" if Address.distance(expected, candidate) > max_distance
      end
      result.merge("score" => score.clamp(0, 100), "rejections" => reasons)
    end

    def result(precision, best, candidates)
      { "precision" => precision, "candidate" => best, "candidates" => candidates }
    end
  end
end
