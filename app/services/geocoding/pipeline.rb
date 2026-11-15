module Geocoding
  class Pipeline
    def initialize(company_id:, georef: nil, photon: nil, gemini: nil)
      @province = Company.where(id: company_id).pick(:province)
      @georef = georef || Georef.new(company_id: company_id)
      @photon = photon || Photon.new(company_id: company_id)
      @gemini = gemini || Gemini.new(company_id: company_id)
      @evaluator = Evaluator.new
    end

    def prefetch(addresses)
      @georef.batch(addresses) if addresses.any?
    end

    def call(data, context: {}, attempts: 0)
      @attempts, @warnings = attempts, []
      if @province && data["province"].present? && Address.context_key(data["province"]) != Address.context_key(@province)
        return { "normalized" => Address.normalize(data, context), "precision" => "unlocated", "candidates" => [], "warnings" => [ "La provincia no coincide con la empresa." ] }
      end
      address = Address.normalize(data.merge("province" => @province || data["province"]), context)
      if data["latitude"].present? || data["longitude"].present?
        unless Address.valid_point?(data["latitude"], data["longitude"], country: address["country"]) && (!@province || ProvinceBoundary.contains?(@province, data["latitude"], data["longitude"]))
          return { "normalized" => address, "precision" => "unlocated", "candidates" => [], "warnings" => [ "Coordenadas inválidas, invertidas o fuera del país. Revisá el archivo." ] }
        end
        candidate = address.slice("street", "house_number", "city", "district", "province", "country").merge(
          "provider" => "user", "latitude" => data["latitude"].to_f, "longitude" => data["longitude"].to_f,
          "precision" => "provided", "type" => "provided", "label" => address["original"])
        # Supplied coordinates are preserved, but require a person's confirmation.
        return { "normalized" => address, "precision" => "approximate", "candidate" => candidate, "candidates" => [ candidate ], "warnings" => [ "Coordenadas aportadas por el usuario; requieren confirmación." ] }
      end
      unless Address.context_key(address["country"]).in?(%w[argentina ar])
        return { "normalized" => address, "precision" => "unlocated", "candidates" => [], "warnings" => [ "Todavía no hay proveedores configurados para este país." ] }
      end
      candidates = []
      if address["geocodable"]
        candidates.concat(safely { @georef.search(address) })
        candidates.concat(safely { @photon.search(address) }) unless @evaluator.call(address, candidates)["precision"] == "reliable"
        unless @evaluator.call(address, candidates)["precision"] == "reliable"
          evaluation = @evaluator.call(address, candidates)
          interpretation = if evaluation["precision"] == "unlocated" || address["missing_information"].present?
            safely { @gemini.interpret(address) }.presence
          end
          if interpretation.is_a?(Hash) && interpretation["geocodable"]
            candidates = candidates.map { |candidate| candidate.merge("interpreted" => true) }
            interpreted = address.merge(interpretation).merge("query" => Address.query(interpretation), "province" => @province || address["province"], "country" => "Argentina")
            interpreted["house_number_approximate"] ||= address["house_number_approximate"]
            %w[between references ambiguities].each { |field| interpreted[field] = (Array(address[field]) + Array(interpreted[field])).uniq }
            changed_query = Address.fold(Address.query(interpreted)) != Address.fold(Address.query(address))
            changed_context = Address::CONTEXT_FIELDS.any? { |field| Address.context_key(interpreted[field]) != Address.context_key(address[field]) }
            if changed_query || changed_context
              extra = safely { @georef.search(interpreted) } + safely { @photon.search(interpreted) }
              candidates.concat(extra.map { |candidate| candidate.merge("interpreted" => true) })
            end
            address = interpreted
          end
          if candidates.empty? && address["city"].present? && Address.query(address) != address["query"]
            candidates.concat(safely { @photon.search(address, alternative: true) })
          end
        end
      end
      @evaluator.call(address, candidates.uniq { |candidate| candidate.slice("provider", "latitude", "longitude", "label") })
        .merge("normalized" => address, "warnings" => @warnings)
    end

    private

    def safely
      yield || []
    rescue Deferred
      raise
    rescue Retryable => error
      raise if @attempts < 2
      @warnings << error.message
      []
    rescue Error => error
      @warnings << error.message
      []
    end
  end
end
