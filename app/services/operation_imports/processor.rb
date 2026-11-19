require "set"

module OperationImports
  class Processor
    ReviewRequired = Class.new(StandardError)

    def self.product_issues(company, keys)
      issues = []
      keys.to_a.each_slice(250) do |slice|
        company.products.where(name_key: slice).pluck(:name_key, :active, :unit).group_by(&:first).each do |name, matches|
          if matches.size > 1
            issues << "Producto ambiguo: #{name}"
          elsif !matches.first[1]
            issues << "Producto inactivo: #{name}"
          elsif matches.first[2] != "unit"
            issues << "Producto con otra unidad: #{name}"
          end
        end
      end
      issues
    end

    def initialize(import)
      @import = import
      @company = import.company
    end

    def read
      @import.source_file.open do |file|
        reader = Reader.new(file.path, @import.source_file.filename)
        buffer = []
        reader.each_row do |raw, number|
          data, issues = Normalizer.call(raw)
          now = Time.current
          buffer << { company_id: @company.id, operation_import_id: @import.id, number: number, original: raw, data: data, issues: issues, created_at: now, updated_at: now }
          if buffer.size >= 200
            OperationImportRow.insert_all(buffer, unique_by: :operation_rows_source_number)
            buffer.clear
          end
        end
        OperationImportRow.insert_all(buffer, unique_by: :operation_rows_source_number) if buffer.any?
      end
      @import.update!(total_rows: @import.rows.count, state: "analyzing")
    end

    def analyze_batch
      keys = @import.rows.where(operation_import_group_id: nil).distinct.limit(100).pluck(Arel.sql("data->>'group_key'"))
      keys.each do |key|
        @import.with_lock do
          rows = @import.rows.where("data->>'group_key' = ?", key)
          first = rows.order(:id).first&.data
          next unless first
          issues = []
          fields = %w[cliente calle localidad codigo_cliente repartidor tipo_pedido fecha_puntual dia_semana hora_desde hora_hasta orden_visita]
          seen_products = Set.new
          unresolved_products = Set.new
          repeated_product = false
          row_count = 0
          rows.find_each(batch_size: 500) do |row|
            row_count += 1
            issues.concat(row.issues)
            issues << "Las filas del grupo tienen datos incompatibles" if fields.any? { |field| row.data[field] != first[field] }
            name = Normalizer.key(row.data["nombre_producto"])
            repeated_product = true if name.present? && seen_products.include?(name)
            seen_products.add(name) if name.present?
            unresolved_products.add(name) if name.present? && row.data["product_id"].blank? && !row.data["new_product"]
          end
          issues.uniq!
          if first["referencia_pedido"].blank? && repeated_product
            issues << "Posibles pedidos independientes con la misma combinación; indicá referencia_pedido"
          end
          if first["tipo_pedido"] != "visita_semanal" && seen_products.empty?
            issues << "El pedido no tiene productos"
          end
          issues.concat(self.class.product_issues(@company, unresolved_products))
          customer, customer_issue = find_customer(first)
          driver, driver_issue = find_driver(first)
          issues << customer_issue if customer_issue
          issues << driver_issue if driver_issue
          if first["codigo_cliente"].present? && @import.rows.where("data->>'customer_key' = ? AND data->>'address_identity_key' <> ?",
              first["customer_key"], first["address_identity_key"]).exists?
            issues << "El mismo código identifica clientes o direcciones diferentes en la planilla"
          end
          if @company.delivery_schedules.where(import_key: key).exists? || @company.delivery_orders.where(import_key: key).exists?
            state = "duplicate"
          else
            state = issues.any? ? "review" : "ready"
          end
          group = @import.groups.create!(company: @company, group_key: key, data: first, issues: issues, state: state,
            customer: customer, driver_profile: driver, row_count: row_count)
          rows.update_all(operation_import_group_id: group.id)
        end
      end
      remaining = @import.rows.where(operation_import_group_id: nil).exists?
      @import.update!(processed_rows: @import.rows.where.not(operation_import_group_id: nil).count, state: remaining ? "analyzing" : "review")
      remaining
    end

    def commit_batch
      ids = @import.groups.where(state: "ready").order(:id).limit(50).pluck(:id)
      customers_to_geocode = Set.new
      ids.each do |id|
        begin
          customer_id = nil
          @import.with_lock do
            next unless @import.state == "importing"
            @company.with_lock do
              group = @import.groups.lock.find(id)
              next unless group.state == "ready"
              customer_id = commit_group(group)
            end
          end
          customers_to_geocode.add(customer_id) if customer_id
        rescue ReviewRequired, ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => error
          @import.groups.where(id: id).update_all(state: "review", issues: [ "No se pudo guardar el grupo: #{error.message.to_s.first(250)}" ])
        end
      end
      customers_to_geocode.each { |customer_id| GeocodeCustomerJob.perform_later(@company.id, customer_id) }
      remaining = @import.groups.where(state: "ready").exists?
      @import.update!(imported_groups: @import.groups.where(state: "imported").count, state: remaining ? "importing" : "finished")
      remaining
    end

    private

    def find_customer(data)
      code = data["codigo_cliente"].presence
      if code
        matches = @company.customers.where("lower(external_code) = ?", code.downcase).limit(2).to_a
        return [ nil, "Código de cliente ambiguo" ] if matches.size > 1
        if matches.one?
          customer = matches.first
          if customer_identity(customer) != source_identity(data)
            return [ nil, "El código ya pertenece a un cliente con otros datos" ]
          end
          return [ customer, nil ]
        end
      end
      candidates = @company.customers.where(import_identity_key: data["address_identity_key"]).limit(3).to_a
      matches = candidates.select { |customer| customer_identity(customer) == source_identity(data) }
      return [ nil, "Hay varios clientes con el mismo nombre y dirección" ] if matches.size > 1
      return [ nil, "El cliente existente tiene otro código" ] if matches.one? && code && matches.first.external_code.present? && Normalizer.key(matches.first.external_code) != Normalizer.key(code)
      [ matches.first, nil ]
    end

    def find_driver(data)
      profiles = @company.driver_profiles.where(name_key: data["driver_key"]).limit(2).to_a
      return [ nil, "Repartidor ambiguo" ] if profiles.size > 1
      [ profiles.first, nil ]
    end

    def customer_identity(customer)
      [ customer.name, customer.address, customer.city ].map { |value| Normalizer.key(value) }
    end

    def source_identity(data)
      %w[cliente calle localidad].map { |field| Normalizer.key(data[field]) }
    end

    def commit_group(group)
      data = group.data
      decision = group.decisions
      key = group.group_key
      if @company.delivery_orders.exists?(import_key: key) || @company.delivery_schedules.exists?(import_key: key)
        group.update!(state: "duplicate")
        return nil
      end
      customer = if decision["new_customer"]
        nil
      elsif decision["customer_id"].present?
        @company.customers.find(decision["customer_id"])
      else
        group.customer || find_customer(data).first
      end
      customer ||= @company.customers.create!(name: data["cliente"], address: data["calle"], city: data["localidad"],
        external_code: data["codigo_cliente"].presence, location_verification: "pending")
      if data["codigo_cliente"].present? && customer.external_code.blank?
        customer.update!(external_code: data["codigo_cliente"])
      end
      driver = if decision["new_driver"]
        nil
      elsif decision["driver_profile_id"].present?
        @company.driver_profiles.find(decision["driver_profile_id"])
      else
        group.driver_profile || find_driver(data).first
      end
      driver ||= @company.driver_profiles.create!(name: data["repartidor"], name_key: data["driver_key"])
      if data["tipo_pedido"] == "pedido_puntual"
        order = @company.delivery_orders.new(customer: customer, driver_profile: driver, import_key: key,
          scheduled_date: Date.iso8601(data["fecha_puntual"]), window_start: data["hora_desde"], window_end: data["hora_hasta"])
        first_row = group.rows.order(:id).first
        raise ReviewRequired, "El pedido no tiene productos" unless first_row
        first_product = product_for(first_row)
        order.delivery_order_items.build(company: @company, product: first_product, description: first_product.name,
          unit: first_product.unit, quantity: first_row.data["cantidad_producto"], position: 0)
        order.save!
        add_items(group, order, except_row_id: first_row.id, start_position: 1)
      else
        schedule = @company.delivery_schedules.new(customer: customer, driver_profile: driver, import_key: key,
          weekday: data["dia_semana"], starts_on: @company.local_date, operation_kind: data["tipo_pedido"],
          window_start: data["hora_desde"], window_end: data["hora_hasta"], visit_order: data["orden_visita"])
        schedule.save!
        add_items(group, schedule) if data["tipo_pedido"] == "pedido_semanal"
      end
      group.update!(state: "imported", customer: customer, driver_profile: driver)
      customer.id unless customer.located?
    end

    def add_items(group, parent, except_row_id: nil, start_position: 0)
      rows = group.rows
      rows = rows.where.not(id: except_row_id) if except_row_id
      item_class = parent.is_a?(DeliveryOrder) ? DeliveryOrderItem : DeliveryScheduleItem
      parent_key = parent.is_a?(DeliveryOrder) ? :delivery_order : :delivery_schedule
      position = start_position
      buffer = []
      rows.find_each(batch_size: 200) do |row|
        product = product_for(row)
        item = item_class.new(company: @company, parent_key => parent, product: product,
          description: product.name, unit: product.unit, quantity: row.data["cantidad_producto"], position: position)
        raise ActiveRecord::RecordInvalid, item unless item.valid?
        buffer << item.attributes.except("id", "created_at", "updated_at")
        position += 1
        if buffer.size >= 200
          item_class.insert_all!(buffer)
          buffer.clear
        end
      end
      item_class.insert_all!(buffer) if buffer.any?
    end

    def product_for(row)
      name = row.data["nombre_producto"]
      return @company.products.create!(name: name, unit: "unit") if row.data["new_product"]
      if row.data["product_id"].present?
        selected = @company.products.find(row.data["product_id"])
        unless selected.name_key == Normalizer.key(name) && selected.active? && selected.unit == "unit"
          raise ReviewRequired, "El producto elegido ya no coincide: #{name}"
        end
        return selected
      end
      matches = @company.products.where(name_key: Normalizer.key(name)).limit(2).to_a
      raise ReviewRequired, "Producto ambiguo: #{name}" if matches.size > 1
      product = matches.one? && Normalizer.key(matches.first.name) == Normalizer.key(name) ? matches.first : nil
      product ||= @company.products.create!(name: name, unit: "unit")
      raise ReviewRequired, "Producto inactivo: #{name}" unless product.active?
      raise ReviewRequired, "Producto con otra unidad: #{name}" unless product.unit == "unit"
      product
    end
  end
end
