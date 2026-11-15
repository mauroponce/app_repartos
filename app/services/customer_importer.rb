class CustomerImporter
  FIELDS = %w[external_code name contact phone email address city latitude longitude status].freeze
  LABELS = %w[Código\ externo Nombre Contacto Teléfono Email Dirección Ciudad Latitud Longitud Estado].zip(FIELDS).to_h.invert.freeze
  HEADER_ALIASES = {
    "codigo" => "external_code", "id_cliente" => "external_code", "codigo externo" => "external_code",
    "nombre" => "name", "cliente" => "name", "comercio" => "name", "razon social" => "name",
    "contacto" => "contact", "responsable" => "contact", "telefono" => "phone", "celular" => "phone",
    "correo" => "email", "direccion" => "address", "domicilio" => "address", "ciudad" => "city", "localidad" => "city",
    "latitud" => "latitude", "longitud" => "longitude", "estado" => "status", "activo" => "status"
  }.merge(FIELDS.index_with(&:itself)).freeze
  Row = Data.define(:number, :customer, :errors, :warnings, :action, :changes, :original, :excluded)
  class InvalidImport < StandardError; end

  def initialize(customer_import)
    @import = customer_import
  end

  def self.default_mapping(headers)
    headers.each_with_index.each_with_object({}) do |(header, index), mapping|
      field = HEADER_ALIASES[ActiveSupport::Inflector.transliterate(header).downcase.strip]
      mapping[field] ||= index.to_s if field
    end
  end

  def preview
    # Bound reads to one directory scan, rather than one lookup per row.
    mapped = @import.rows.map { |values| attributes_for(values) }
    codes = @import.company.customers.where(external_code: mapped.filter_map { |attributes| attributes["external_code"] }).index_by(&:external_code)
    names = @import.company.customers.where("LOWER(name) IN (?)", mapped.filter_map { |attributes| attributes["name"]&.downcase }).pluck(:name, :address, :city).group_by { |row| row.first.downcase }
    used_codes = {}
    @import.rows.each_with_index.map do |values, index|
      number = index + 2
      excluded = values.all?(&:blank?) || @import.excluded_rows.include?(number)
      attributes, errors, warnings = attributes_for(values), [], []
      code = attributes["external_code"].presence
      customer = @import.company.customers.new
      if codes[code]
        # dup removes identity; use a fresh instance so repeated codes do not
        # mutate another preview row or its persisted comparison.
        customer = Customer.instantiate(codes[code].attributes)
      end
      original = customer.attributes
      action = customer.persisted? ? "Actualizar" : "Crear"
      unless excluded
        errors << "Código externo repetido (fila #{used_codes[code]})." if code && used_codes[code]
        used_codes[code] = number if code
        @import.headers.each_with_index do |header, column|
          next unless header.downcase.strip.in?(%w[company_id empresa_id customer_id user_id]) && values[column].present?
          errors << "No se admiten referencias internas a empresas, clientes o usuarios. Quitá la columna #{header}."
        end
        begin
          %w[latitude longitude].each { |field| attributes[field] = coordinate(attributes[field], limit: field == "latitude" ? 90 : 180) if attributes.key?(field) }
          attributes["status"] = status(attributes["status"]) if attributes.key?("status") && attributes["status"].present?
          attributes.delete("status") if attributes["status"].blank? && !@import.overwrite_blanks?
          customer.assign_attributes(attributes)
          # A supplied point explicitly confirms an address change, including
          # when its numeric values happen to be unchanged.
          customer.location_confirmed = true if attributes["latitude"].present? && attributes["longitude"].present?
          customer.valid?
          errors.concat(customer.errors.full_messages)
        rescue InvalidImport => error
          errors << error.message
        end
        if code.blank?
          warnings << "Sin código: crea un cliente nuevo; reimportar puede duplicarlo."
          if (matches = names[customer.name.to_s.downcase]).present?
            warnings << "Coincidencias por nombre (no se fusionan): #{matches.first(5).map { |row| row.join(' · ') }.join('; ')}"
          end
        end
      end
      changes = customer.changes.slice(*FIELDS).transform_keys { |field| LABELS.fetch(field) }
      Row.new(number: number, customer: customer, errors: errors.uniq, warnings: warnings, action: action, changes: changes, original: original, excluded: excluded)
    end
  end

  def digest(rows = preview)
    Digest::SHA256.hexdigest(canonical([ @import.mapping, @import.excluded_rows, @import.overwrite_blanks,
      rows.map { |row| [ row.number, row.original, row.customer.attributes, row.errors, row.warnings, row.excluded ] } ]).to_json)
  end

  def confirm!(preview_digest:, acknowledge_duplicates: false)
    @import.company.with_lock do
      @import.lock!
      return @import.summary if @import.confirmed_at
      raise InvalidImport, "La previsualización venció. Volvé a cargar el archivo." if @import.expired?
      rows = preview
      raise InvalidImport, "Los datos cambiaron. Revisá la nueva previsualización antes de confirmar." unless ActiveSupport::SecurityUtils.secure_compare(digest(rows), preview_digest.to_s)
      selected = rows.reject(&:excluded)
      raise InvalidImport, "Hay filas inválidas o ninguna fila seleccionada. Corregí o excluí las filas antes de importar." if selected.empty? || selected.any? { |row| row.errors.any? }
      if selected.any? { |row| row.warnings.any? } && !acknowledge_duplicates
        raise InvalidImport, "Revisá las coincidencias y confirmá que los clientes sin código se crean sin fusionar."
      end
      summary = { "created" => selected.count { |row| row.customer.new_record? }, "updated" => selected.count { |row| row.customer.persisted? },
        "skipped" => rows.count(&:excluded), "pending_location" => selected.count { |row| !row.customer.located? }, "errors" => 0 }
      selected.each { |row| row.customer.save! }
      @import.update!(summary: summary, confirmed_at: Time.current)
      summary
    end
  end

  private

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end

  def attributes_for(values)
    @import.mapping.slice(*FIELDS).each_with_object({}) do |(field, column), attributes|
      next if column.blank?
      value = values[column.to_i].to_s.strip.presence
      next if value.nil? && !@import.overwrite_blanks?
      value = value.gsub(/[\s().-]/, "") if field == "phone" && value
      attributes[field] = value
    end
  end

  def coordinate(value, limit:)
    return nil if value.blank?
    text = value.to_s.tr(",", ".")
    raise InvalidImport, "Coordenada inválida: #{value}" unless text.size <= 128 && text.match?(/\A[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d{1,3})?\z/)
    number = BigDecimal(text)
    raise InvalidImport, "Coordenada fuera de rango: #{value}" unless number.between?(-limit, limit)
    number.round(7)
  end

  def status(value)
    case ActiveSupport::Inflector.transliterate(value.to_s).downcase
    when "active", "activo", "true", "1", "si", "yes" then "active"
    when "inactive", "inactivo", "false", "0", "no" then "inactive"
    else raise InvalidImport, "Estado inválido: usá activo/inactivo, sí/no o 1/0."
    end
  end
end
