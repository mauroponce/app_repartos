module Geocoding
  class Georef
    def initialize(company_id:, http: nil)
      @http = http || HttpClient.new(provider: "georef", url: ENV.fetch("GEOREF_API_URL", "https://apis.datos.gob.ar/georef/api/v2.0"))
      @cache = Cache.new(company_id, "georef", "v2-parser-1:#{@http.identity}")
    end

    def search(address)
      batch([ address ]).first
    end

    def batch(addresses)
      keys = addresses.map { |address| parameters(address) }
      results = keys.to_h { |input| [ input, @cache.read(input) ] }
      missing = results.select { |_key, value| value.nil? }.keys
      missing.each_slice(25) do |inputs|
        response = @http.call(path: "direcciones", body: { direcciones: inputs })
        values = response["resultados"]
        raise InvalidResponse, "Georef devolvió un lote inválido." unless values.is_a?(Array) && values.size == inputs.size
        inputs.zip(values).each do |input, value|
          raise InvalidResponse, "Georef devolvió direcciones inválidas." unless value.is_a?(Hash) && value["direcciones"].is_a?(Array)
          # Per-item API errors must not be persisted as successful negative hits.
          raise Error, "Georef rechazó una dirección del lote." if value["errores"].present?
          candidates = value["direcciones"].first(10).map { |item| candidate(item, value["total"].to_i > 10) }
          results[input] = @cache.write(input, { "candidates" => candidates }, empty: candidates.empty?)
        end
      end
      keys.map { |input| results.fetch(input).fetch("candidates") }
    rescue TypeError, NoMethodError, KeyError
      raise InvalidResponse, "Georef devolvió una estructura inválida."
    end

    private

    def parameters(address)
      { "direccion" => Address.query(address), "provincia" => address["province"], "departamento" => address["district"],
        "localidad" => address["city"], "max" => 10, "campos" => "completo" }.compact_blank
    end

    def candidate(item, truncated)
      raise InvalidResponse, "Georef devolvió una dirección inválida." unless item.is_a?(Hash)
      { "provider" => "georef", "street" => item.dig("calle", "nombre"), "house_number" => item.dig("altura", "valor")&.to_s,
        "city" => item.dig("localidad", "nombre"), "census_city" => item.dig("localidad_censal", "nombre"),
        "district" => item.dig("departamento", "nombre"), "province" => item.dig("provincia", "nombre"), "country" => "Argentina",
        "intersection" => item.dig("calle_cruce_1", "nombre"), "latitude" => item.dig("ubicacion", "lat"), "longitude" => item.dig("ubicacion", "lon"),
        "label" => Address.clean(item["nomenclatura"]), "precision" => "interpolated", "type" => "address", "truncated" => truncated }
    rescue TypeError, NoMethodError
      raise InvalidResponse, "Georef devolvió una estructura inválida."
    end
  end
end
