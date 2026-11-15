require "net/http"

module Osrm
  class Client
    class Error < StandardError; end
    class Unavailable < Error; end
    class InvalidResponse < Error; end
    class NoRoute < Error; end
    class OutsideCoverage < NoRoute; end
    MAX_COORDINATES = 101
    MAX_BYTES = 8_000_000

    def initialize(url: ENV["OSRM_URL"], transport: nil, sleeper: ->(seconds) { sleep(seconds) })
      @uri = URI.parse(url.to_s)
      unless @uri.is_a?(URI::HTTP) && @uri.host.present? && !@uri.userinfo && @uri.path.in?([ "", "/" ]) && !@uri.query && !@uri.fragment
        raise Unavailable, "OSRM no está configurado. La planificación manual sigue disponible."
      end
      @transport, @sleeper = transport, sleeper
    rescue URI::InvalidURIError
      raise Unavailable, "La configuración de OSRM no es válida"
    end

    def table(coordinates)
      points = validate_coordinates(coordinates)
      body = get("table", points, annotations: "duration,distance")
      matrices = %w[durations distances].to_h do |key|
        rows = body[key]
        unless rows.is_a?(Array) && rows.size == points.size && rows.all? { |row| row.is_a?(Array) && row.size == points.size && row.all? { |v| v.nil? || nonnegative?(v) } }
          raise InvalidResponse, "OSRM devolvió una matriz incompleta o inválida"
        end
        [ key.to_sym, rows ]
      end
      points.size.times do |i|
        points.size.times do |j|
          raise InvalidResponse, "OSRM devolvió conexiones incompletas" unless matrices[:durations][i][j].nil? == matrices[:distances][i][j].nil?
        end
      end
      raise InvalidResponse, "OSRM utilizó distancias aproximadas no autorizadas" if body["fallback_speed_cells"].present?
      matrices
    end

    def route(coordinates)
      points = validate_coordinates(coordinates, limit: MAX_COORDINATES + 1)
      body = get("route", points, overview: "full", geometries: "geojson", steps: "false")
      route = body.fetch("routes", []).first
      unless route.is_a?(Hash) && nonnegative?(route["distance"]) && nonnegative?(route["duration"]) && route["legs"].is_a?(Array) && route["legs"].size == points.size - 1 && route["legs"].all? { |leg| leg.is_a?(Hash) && nonnegative?(leg["distance"]) && nonnegative?(leg["duration"]) }
        raise InvalidResponse, "OSRM devolvió un recorrido incompleto"
      end
      geometry = route["geometry"]
      unless geometry.is_a?(Hash) && geometry["type"] == "LineString" && geometry["coordinates"].is_a?(Array) && geometry["coordinates"].size.in?(2..100_000) && geometry["coordinates"].all? { |point| valid_point?(point) }
        raise InvalidResponse, "OSRM devolvió una geometría inválida"
      end
      route.slice("distance", "duration", "geometry", "legs")
    end

    def available?
      table([ [ -58.3816, -34.6037 ], [ -58.3830, -34.6050 ] ])
      true
    rescue Error
      false
    end

    def cache_identity
      RouteOptimization::Dataset.identity
    end

    private

    def validate_coordinates(points, limit: MAX_COORDINATES)
      unless points.is_a?(Array) && points.size.in?(2..limit) && points.all? { |point| valid_point?(point) }
        raise Error, "Ingresá entre 2 y #{limit} coordenadas válidas en orden longitud, latitud"
      end
      normalized = points.map { |point| point.map(&:to_f) }
      RouteOptimization::Dataset.validate_coverage!(normalized, url: @uri.to_s)
      normalized
    end

    def valid_point?(point)
      point.is_a?(Array) && point.size == 2 && point.all? { |v| v.is_a?(Numeric) && v.finite? } && point[0].between?(-180, 180) && point[1].between?(-90, 90)
    end

    def nonnegative?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def get(service, points, options)
      uri = @uri.dup
      uri.path = "/#{service}/v1/driving/#{points.map { |pair| pair.join(',') }.join(';')}"
      uri.query = URI.encode_www_form(options.merge(radiuses: points.map { "1000" }.join(";")))
      attempts = 0
      begin
        attempts += 1
        response = @transport ? @transport.call(uri) : request(uri)
        raise Unavailable, "OSRM está temporalmente fuera de servicio" if response.code.to_i >= 500 || response.code.to_i == 429
        raise InvalidResponse, "La respuesta de OSRM es demasiado grande" if response.body.to_s.bytesize > MAX_BYTES
        body = JSON.parse(response.body)
        raise InvalidResponse, "OSRM devolvió una respuesta inválida" unless body.is_a?(Hash)
        raise OutsideCoverage, "Esta ubicación está fuera de la zona disponible para optimización o no tiene una calle accesible en el mapa activo" if body["code"] == "NoSegment"
        raise NoRoute, "OSRM no encuentra conexión vial entre las paradas; revisá las coordenadas y la cobertura del mapa" if body["code"].in?(%w[NoRoute NoTable])
        raise InvalidResponse, "OSRM rechazó el cálculo vial" unless response.code.to_i.in?(200..299)
        raise InvalidResponse, "OSRM no pudo calcular este recorrido" unless body["code"] == "Ok"
        body
      rescue Unavailable, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
        if attempts < 2
          @sleeper.call(0.2)
          retry
        end
        raise Unavailable, "No se pudo conectar con OSRM. Reintentá más tarde; no se modificó la hoja."
      rescue JSON::ParserError, TypeError
        raise InvalidResponse, "OSRM devolvió JSON inválido"
      end
    end

    def request(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 12, write_timeout: 3, max_retries: 0) do |http|
        http.request_get(uri.request_uri) do |response|
          data = +""
          response.read_body do |chunk|
            data << chunk
            raise InvalidResponse, "La respuesta de OSRM es demasiado grande" if data.bytesize > MAX_BYTES
          end
          response.body = data
          return response
        end
      end
    end
  end
end
