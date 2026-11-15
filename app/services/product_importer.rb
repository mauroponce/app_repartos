class ProductImporter
  FIELDS = %w[sku name unit package_content_quantity package_content_unit active].freeze
  HEADER_ALIASES = {
    "sku" => "sku", "codigo" => "sku", "código" => "sku",
    "name" => "name", "nombre" => "name", "producto" => "name",
    "unit" => "unit", "unidad" => "unit",
    "package_content_quantity" => "package_content_quantity", "contenido" => "package_content_quantity",
    "package_content_unit" => "package_content_unit", "unidad de contenido" => "package_content_unit",
    "active" => "active", "activo" => "active"
  }.freeze
  Row = Data.define(:number, :product, :errors, :action)
  UNIT_ALIASES = { "bolsa" => "bag", "unidad" => "unit", "caja" => "box", "paquete" => "pack", "kilogramo" => "kg", "kilo" => "kg", "gramo" => "g", "litro" => "l" }.freeze
  class InvalidImport < StandardError; end

  def initialize(product_import)
    @import = product_import
  end

  def self.default_mapping(headers)
    headers.each_with_index.each_with_object({}) do |(header, index), mapping|
      field = HEADER_ALIASES[header.downcase]
      mapping[field] = index.to_s if field && !mapping.key?(field)
    end
  end

  def self.normalize_unit(value)
    text = value.to_s.strip.downcase.presence
    UNIT_ALIASES.fetch(text, text)
  end

  def preview
    used_skus = {}
    @import.rows.each_with_index.filter_map do |values, index|
      next if values.all?(&:blank?)
      attributes = mapped_attributes(values)
      %w[unit package_content_unit].each { |field| attributes[field] = self.class.normalize_unit(attributes[field]) }
      errors = []
      %w[name unit].each { |field| errors << "Mapeá la columna #{field}." unless @import.mapping[field].present? }
      begin
        attributes["package_content_quantity"] = decimal(attributes["package_content_quantity"])
        attributes["active"] = boolean(attributes["active"])
      rescue InvalidImport => e
        errors << e.message
      end
      sku = attributes["sku"].to_s.strip.presence
      product = sku && @import.company.products.find_by(sku: sku)
      product ||= @import.company.products.new
      action = product.persisted? ? "Actualizar" : "Crear"
      product.assign_attributes(attributes)
      product.valid?
      errors.concat(product.errors.full_messages)
      errors << "SKU repetido en el archivo (fila #{used_skus[sku]})." if sku && used_skus[sku]
      used_skus[sku] = index + 2 if sku
      Row.new(number: index + 2, product: product, errors: errors, action: action)
    end
  end

  def confirm!(acknowledge_without_sku: false)
    @import.company.with_lock do
      @import.lock!
      return 0 if @import.confirmed_at
      raise InvalidImport, "La previsualización venció. Volvé a cargar el archivo." if @import.expired?
      rows = preview
      raise InvalidImport, "Hay filas inválidas. Corregí el archivo o el mapeo antes de importar." if rows.empty? || rows.any? { |row| row.errors.any? }
      if rows.any? { |row| row.product.sku.blank? } && !acknowledge_without_sku
        raise InvalidImport, "Confirmá que las filas sin SKU crean productos nuevos y no permiten reconocer futuras reimportaciones."
      end
      rows.each { |row| row.product.save! }
      @import.update!(confirmed_at: Time.current)
      rows.size
    end
  end

  private

  def mapped_attributes(values)
    FIELDS.index_with do |field|
      column = @import.mapping[field]
      column.present? && column.to_s.match?(/\A\d+\z/) ? values[column.to_i].to_s.strip.presence : nil
    end
  end

  def decimal(value)
    return nil if value.blank?
    text = value.to_s.strip
    if text.include?(",") && text.include?(".")
      if text.rindex(",") > text.rindex(".")
        raise InvalidImport, "Contenido decimal inválido: #{value}" unless text.match?(/\A\d{1,3}(?:\.\d{3})+,\d+\z/)
        text = text.delete(".").tr(",", ".")
      else
        raise InvalidImport, "Contenido decimal inválido: #{value}" unless text.match?(/\A\d{1,3}(?:,\d{3})+\.\d+\z/)
        text = text.delete(",")
      end
    else
      text = text.tr(",", ".")
    end
    raise InvalidImport, "Contenido decimal inválido: #{value}" unless text.match?(/\A\d+(?:\.\d{1,3})?\z/)
    text
  end

  def boolean(value)
    return true if value.blank?
    case value.to_s.downcase
    when "true", "1", "sí", "si", "yes" then true
    when "false", "0", "no" then false
    else raise InvalidImport, "Activo debe ser true/false, sí/no o 1/0."
    end
  end
end
