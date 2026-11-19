require "digest"

module OperationImports
  class Normalizer
    WEEKDAYS = { "lunes" => 1, "martes" => 2, "miercoles" => 3, "jueves" => 4, "viernes" => 5, "sabado" => 6, "domingo" => 7 }.freeze
    TYPES = %w[visita_semanal pedido_semanal pedido_puntual].freeze

    def self.key(value)
      Geocoding::Address.fold(value)
    end

    def self.call(raw)
      data = raw.transform_values { |value| value.to_s.strip }
      issues = []
      %w[repartidor cliente localidad calle].each { |field| issues << "Falta #{field}" if data[field].blank? }
      %w[repartidor cliente localidad calle nombre_producto codigo_cliente referencia_pedido].each do |field|
        issues << "#{field} supera el límite" if data[field].to_s.length > (field == "cliente" ? 90 : 255)
      end
      issues << "Tipo de pedido inválido" unless TYPES.include?(data["tipo_pedido"])
      if data["tipo_pedido"] == "pedido_puntual"
        date = parse_date(data["fecha_puntual"])
        issues << "Fecha puntual inválida" unless date
        issues << "Un pedido puntual no lleva día semanal" if data["dia_semana"].present?
        data["fecha_puntual"] = date&.iso8601
      else
        day = WEEKDAYS[key(data["dia_semana"])]
        issues << "Día semanal inválido" unless day
        issues << "Una programación no lleva fecha puntual" if data["fecha_puntual"].present?
        data["dia_semana"] = day
      end
      if data["hora_desde"].present? || data["hora_hasta"].present?
        from = parse_time(data["hora_desde"])
        to = parse_time(data["hora_hasta"])
        issues << "Horario incompleto o inválido" unless from && to && from < to
        data["hora_desde"], data["hora_hasta"] = from, to
      else
        data["hora_desde"], data["hora_hasta"] = nil, nil
      end
      if data["tipo_pedido"] == "visita_semanal"
        issues << "Una visita no lleva mercadería" if data["nombre_producto"].present? || data["cantidad_producto"].present?
      elsif data["tipo_pedido"].in?(TYPES)
        issues << "Falta producto" if data["nombre_producto"].blank?
        quantity = parse_quantity(data["cantidad_producto"])
        issues << "Cantidad inválida" unless quantity
        data["cantidad_producto"] = quantity&.to_s
      end
      if data["orden_visita"].present?
        order = Integer(data["orden_visita"], exception: false)
        issues << "Orden de visita inválido" unless order && order.between?(1, 1_000_000)
        data["orden_visita"] = order
      else
        data["orden_visita"] = nil
      end
      data["customer_key"] = if data["codigo_cliente"].present?
        "code:#{key(data['codigo_cliente'])}"
      else
        "address:#{[ 'cliente', 'calle', 'localidad' ].map { |field| key(data[field]) }.join('|')}"
      end
      data["driver_key"] = key(data["repartidor"])
      data["address_identity_key"] = %w[cliente calle localidad].map { |field| key(data[field]) }.join("|")
      data["geocode_address_key"] = %w[calle localidad].map { |field| key(data[field]) }.join("|")
      data["product_key"] = key(data["nombre_producto"])
      identity = [ data["customer_key"], data["driver_key"], data["tipo_pedido"] ]
      if data["referencia_pedido"].present?
        identity << "ref:#{key(data['referencia_pedido'])}"
      else
        identity.concat([ data["fecha_puntual"], data["dia_semana"], data["hora_desde"], data["hora_hasta"] ])
      end
      data["group_key"] = Digest::SHA256.hexdigest(identity.join("\0"))
      [ data, issues ]
    end

    def self.parse_date(value)
      return nil if value.blank?
      return (Date.new(1899, 12, 30) + value.to_i) if value.to_s.match?(/\A\d{5}\z/)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def self.parse_time(value)
      return nil if value.blank?
      if value.to_s.match?(/\A0?\.\d+\z/)
        minutes = (value.to_f * 1440).round
        return format("%02d:%02d", minutes / 60, minutes % 60) if minutes.between?(0, 1439)
      end
      match = value.to_s.match(/\A(\d{1,2}):(\d{2})(?::00)?\z/)
      format("%02d:%02d", match[1].to_i, match[2].to_i) if match && match[1].to_i < 24 && match[2].to_i < 60
    end

    def self.parse_quantity(value)
      quantity = BigDecimal(value.to_s.tr(",", "."))
      quantity if quantity > 0 && quantity < 1_000_000_000 && quantity.frac.zero?
    rescue ArgumentError
      nil
    end
  end
end
