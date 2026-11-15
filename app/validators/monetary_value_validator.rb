class MonetaryValueValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    raw = record.public_send("#{attribute}_before_type_cast")
    return if raw.blank? && options[:allow_nil]
    decimal = BigDecimal(raw.to_s, exception: false)
    signed = options[:signed]
    unless decimal&.finite? && decimal.abs < 1_000_000_000_000 && (signed || decimal >= 0) && decimal == decimal.round(4)
      record.errors.add(attribute, "debe ser un importe válido con hasta 4 decimales#{signed ? '' : ', sin valores negativos'}")
    end
  end
end
