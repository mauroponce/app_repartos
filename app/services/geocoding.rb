module Geocoding
  class Error < StandardError; end
  class InvalidResponse < Error; end
  class QuotaExceeded < Error; end
  class Retryable < Error
    attr_reader :wait
    def initialize(message = "Servicio geográfico temporalmente no disponible.", wait: 15)
      @wait = wait.clamp(1, 3600)
      super(message)
    end
  end
  class Deferred < Retryable
    def initialize(wait)
      super("Esperando el límite de consultas del proveedor.", wait: wait)
    end
  end
end
