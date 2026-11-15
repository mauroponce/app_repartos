require "net/http"

module Geocoding
  class HttpClient
    MAX_BYTES = 2.megabytes

    def initialize(provider:, url:, transport: nil)
      @provider, @uri, @transport = provider, URI.parse(url), transport
      unless @uri.is_a?(URI::HTTP) && @uri.host.present? && !@uri.userinfo && !@uri.query && !@uri.fragment
        raise Error, "URL del proveedor inválida."
      end
    rescue URI::InvalidURIError
      raise Error, "URL del proveedor inválida."
    end

    def identity
      Digest::SHA256.hexdigest(@uri.to_s)
    end

    def call(path: nil, query: nil, body: nil, headers: {})
      prefix = @provider.upcase
      default_limit = @provider.in?(%w[photon gemini]) ? 100 : 2000
      limit = Config.integer("#{prefix}_DAILY_LIMIT", default_limit, 0..100_000)
      limit = [ limit, 100 ].min if @provider == "photon" && Config.public_photon?
      interval = Config.integer("#{prefix}_INTERVAL_MS", @provider == "photon" ? 1500 : 1000, 0..60_000)
      interval = [ interval, 1500 ].max if @provider == "photon" && Config.public_photon?
      GeocodingProviderState.reserve!(@provider, interval: interval / 1000.0, limit: limit)
      uri = @uri.dup
      uri.path = "#{uri.path.delete_suffix('/')}/#{path}" if path
      uri.query = URI.encode_www_form(query) if query
      request = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "AppRepartos/1.0"
      headers.each { |key, value| request[key] = value }
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      response = @transport ? @transport.call(uri, request) : perform(uri, request)
      code = response.code.to_i
      if code == 429 || code >= 500
        wait = response["Retry-After"].to_i.clamp(15, 3600)
        GeocodingProviderState.where(provider: @provider).update_all(available_at: Time.current + wait.seconds)
        raise Retryable.new(wait: wait)
      end
      raise Error, "El proveedor #{@provider} rechazó la consulta (#{code})." unless code.in?(200..299)
      raise InvalidResponse, "Respuesta demasiado grande de #{@provider}." if response.body.to_s.bytesize > MAX_BYTES
      payload = JSON.parse(response.body)
      raise InvalidResponse, "JSON inválido de #{@provider}." unless payload.is_a?(Hash)
      payload
    rescue JSON::ParserError, TypeError
      record_error
      raise InvalidResponse, "JSON inválido de #{@provider}."
    rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, SocketError
      record_error
      raise Retryable
    rescue Error => error
      record_error unless error.is_a?(Deferred) || error.is_a?(QuotaExceeded)
      raise
    end

    private

    def record_error
      GeocodingProviderState.where(provider: @provider).update_all("error_count = error_count + 1")
    end

    def perform(uri, request)
      timeout = Config.integer("GEOCODING_TIMEOUT_SECONDS", 10, 1..30)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: timeout, write_timeout: 3, max_retries: 0) do |http|
        http.request(request) do |response|
          content = +""
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response.read_body do |chunk|
            content << chunk
            raise InvalidResponse, "Respuesta demasiado grande de #{@provider}." if content.bytesize > MAX_BYTES
            raise Retryable if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > timeout
          end
          response.body = content
          response
        end
      end
    end
  end
end
