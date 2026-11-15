module CustomerImports
  class Preparation
    FIELDS = (CustomerImporter::FIELDS + %w[district province postal_code country]).freeze
    LABELS = CustomerImporter::LABELS.merge("city" => "Localidad", "district" => "Partido / departamento", "province" => "Provincia", "postal_code" => "Código postal", "country" => "País").freeze
    ALIASES = CustomerImporter::HEADER_ALIASES.merge("partido" => "district", "departamento" => "district", "provincia" => "province", "codigo postal" => "postal_code", "cp" => "postal_code", "pais" => "country").freeze

    def self.mapping(headers)
      headers.each_with_index.each_with_object({}) do |(header, index), mapping|
        field = ALIASES[Geocoding::Address.fold(header)]
        mapping[field] ||= index.to_s if field
      end
    end

    def self.attributes(import, original)
      attributes = import.mapping.each_with_object({}) do |(field, column), result|
        result[field] = Geocoding::Address.clean(original[column.to_i]).presence if column.present? && FIELDS.include?(field)
      end
      import.geographic_context.each { |field, value| attributes[field] ||= value if Geocoding::Address::CONTEXT_FIELDS.include?(field) }
      attributes["phone"] = attributes["phone"]&.gsub(/[\s().-]/, "")
      attributes["email"] = attributes["email"]&.downcase
      if attributes["status"].present?
        attributes["status"] = case Geocoding::Address.fold(attributes["status"])
        when "activo", "active", "si", "1", "true" then "active"
        when "inactivo", "inactive", "no", "0", "false" then "inactive"
        else attributes["status"]
        end
      end
      attributes.compact
    end

    def self.call(import)
      import.import_rows.where(normalized: {}).order(:id).limit(100).each do |row|
        attributes = attributes(import, row.original)
        address = Geocoding::Address.normalize(attributes, import.geographic_context.merge("province" => import.company.province))
        attributes["city"] ||= address["city"] if address["city"].present?
        issues = []
        if attributes["province"].present? && Geocoding::Address.context_key(attributes["province"]) != Geocoding::Address.context_key(import.company.province)
          issues << "La provincia de la fila difiere de la provincia de la empresa (#{import.company.province})."
        end
        if attributes["country"].present? && !Geocoding::Address.context_key(attributes["country"]).in?(%w[argentina ar])
          issues << "El país de la fila debe ser Argentina."
        end
        attributes["province"] = import.company.province
        address["province"] = import.company.province
        import.headers.each_with_index do |header, column|
          if header.downcase.strip.in?(%w[company_id empresa_id customer_id user_id]) && row.original[column].present?
            issues << "No se admiten referencias internas a empresas, clientes o usuarios."
          end
        end
        customer = import.company.customers.new(attributes.slice(*CustomerImporter::FIELDS).except("latitude", "longitude"))
        customer.valid?
        # A city mixed into the address can still be extracted in the pipeline.
        issues.concat(customer.errors.full_messages.reject { |message| customer.errors[:city].any? && message == customer.errors.full_message(:city, customer.errors[:city].first) })
        if attributes["latitude"].present? || attributes["longitude"].present?
          lat, lon = attributes.values_at("latitude", "longitude").map { |value| value&.tr(",", ".") }
          if Geocoding::Address.valid_point?(lat, lon, country: address["country"]) && Geocoding::ProvinceBoundary.contains?(import.company.province, lat, lon)
            attributes.merge!("latitude" => lat, "longitude" => lon)
          else
            issues << "Coordenadas inválidas, invertidas o fuera de la provincia de la empresa."
          end
        end
        row.update!(data: attributes, normalized: address, issues: issues.uniq,
          excluded: row.original.all?(&:blank?),
          address_key: Digest::SHA256.hexdigest([ address["query"], *address.values_at(*Geocoding::Address::CONTEXT_FIELDS) ].map { |value| Geocoding::Address.fold(value) }.to_json),
          duplicate_key: Digest::SHA256.hexdigest([ attributes["name"], attributes["address"], attributes["city"] ].map { |value| Geocoding::Address.fold(value) }.to_json))
      end
      return false if import.import_rows.where(normalized: {}).exists?

      # Resolve duplicate groups before the first provider request. Repeated
      # addresses reuse provider caches but remain separate customer rows.
      import.import_rows.find_each(batch_size: 100) do |row|
        duplicates = []
        issues = row.issues.dup
        if (code = row.data["external_code"]).present?
          duplicates.concat(import.company.customers.where(external_code: code).limit(5).pluck(:id).map { |id| "Cliente existente ##{id} con el mismo código (no se modificará)." })
          import.import_rows.where("id < ?", row.id).where("data->>'external_code' = ?", code).limit(5).pluck(:number).each { |number| duplicates << "Código repetido en fila #{number}."; issues << "Código externo repetido en el archivo (fila #{number})." }
        end
        duplicates.concat(import.company.customers.where("LOWER(name) = ?", row.data["name"].to_s.downcase).limit(5).pluck(:id).map { |id| "Posible coincidencia con cliente ##{id}." })
        import.import_rows.where(duplicate_key: row.duplicate_key).where("id < ?", row.id).limit(5).pluck(:number).each { |number| duplicates << "Posible duplicado de fila #{number}." }
        warnings = []
        warnings << "Dirección repetida en el archivo; se reutilizarán las consultas." if import.import_rows.where(address_key: row.address_key).where.not(id: row.id).exists?
        row.update!(duplicates: duplicates, warnings: warnings, issues: issues.uniq)
      end
      true
    end
  end
end
