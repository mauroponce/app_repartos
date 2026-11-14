class MerchandiseQuantityValidator < ActiveModel::EachValidator
  MAXIMUM = BigDecimal("999999999.999")

  def validate_each(record, attribute, value)
    raw = record.public_send("#{attribute}_before_type_cast")
    return if raw.blank? && options[:allow_nil]

    number = BigDecimal(raw.to_s, exception: false)
    if !number&.finite? || number > MAXIMUM || (options[:zero] ? number.negative? : number <= 0)
      record.errors.add(attribute, options[:zero] ? "debe ser un número entre 0 y #{MAXIMUM.to_s('F')}" : "debe ser un número positivo menor a 1.000.000.000")
      return
    end
    unit = record.public_send(options.fetch(:unit, :unit))
    if DeliveryUnits::DISCRETE.include?(unit) && number.frac.nonzero?
      record.errors.add(attribute, "debe ser entera para esta unidad")
    elsif number != number.round(3)
      record.errors.add(attribute, "admite hasta tres decimales")
    end
  end
end
