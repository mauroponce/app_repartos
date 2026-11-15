require "net/http"

class VroomClient
  class Error < StandardError; end
  MAX_RESPONSE_BYTES = 10.megabytes

  def self.enabled?
    ENV["MULTIVEHICLE_OPTIMIZATION_ENABLED"] == "true" && ENV["VROOM_URL"].present?
  end

  def self.available?
    return false unless enabled?
    Rails.cache.fetch([ "vroom-health", ENV["VROOM_URL"] ], expires_in: 15.seconds) do
      uri = URI.parse(ENV.fetch("VROOM_URL"))
      next false unless uri.is_a?(URI::HTTP) && uri.host.present? && !uri.userinfo
      uri.path = "#{uri.path.delete_suffix('/')}/health"
      uri.query = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 0.5, read_timeout: 1, write_timeout: 0.5, max_retries: 0) do |http|
        http.request_get(uri.request_uri) { |response| break response.is_a?(Net::HTTPSuccess) }
      end
    end
  rescue URI::InvalidURIError, Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    false
  end

  def call(payload)
    raise Error, "La optimización multivehículo está deshabilitada. Habilitá MULTIVEHICLE_OPTIMIZATION_ENABLED y VROOM_URL después de verificar el servicio; la planificación manual sigue disponible." unless self.class.enabled?
    endpoint = ENV["VROOM_URL"].presence
    raise Error, "La optimización no está configurada. Configurá VROOM_URL para usarla; podés continuar con la planificación manual." unless endpoint
    uri = URI.parse(endpoint)
    raise Error, "La dirección del optimizador no es válida" unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)
    body = +""
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 35, write_timeout: 5) do |http|
      http.max_retries = 0
      http.request(request) do |response|
        raise Error, "El optimizador no pudo responder. Intentá nuevamente." unless response.is_a?(Net::HTTPSuccess)
        response.read_body do |chunk|
          body << chunk
          raise Error, "La respuesta del optimizador es demasiado grande" if body.bytesize > MAX_RESPONSE_BYTES
        end
      end
    end
    result = JSON.parse(body)
    raise Error, "El optimizador no pudo calcular las rutas sobre calles. Revisá las ubicaciones y la configuración del motor de rutas." unless result.is_a?(Hash) && result["code"] == 0
    result
  rescue JSON::ParserError
    raise Error, "El optimizador devolvió una respuesta inválida"
  rescue URI::InvalidURIError
    raise Error, "La dirección del optimizador no es válida"
  rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    raise Error, "No se pudo conectar con el optimizador. Intentá nuevamente o continuá con la planificación manual."
  end
end
