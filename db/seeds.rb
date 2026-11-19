# Demo data is only installed locally. Re-running seeds never changes existing records.
return unless Rails.env.development?

Company.transaction do
  south = Company.find_or_create_by!(slug: "distribuidora-sur") { |company| company.name = "Distribuidora Sur" }
  north = Company.find_or_create_by!(slug: "distribuidora-norte") { |company| company.name = "Distribuidora Norte" }

  [ [ south, "Lucía Pérez", "admin@repartos.test" ], [ north, "Pedro Gómez", "norte@repartos.test" ] ].each do |company, name, email|
    company.users.find_or_create_by!(email_address: email) do |user|
      user.name = name
      user.role = :administrator
      user.password = "Repartos-demo-2026"
    end
  end

  [
    [ "Farmacia Central", "Micaela Silva", "Av. Espora 821", "Adrogué", "active" ],
    [ "Nube Store", "Tomás Méndez", "Av. Hipólito Yrigoyen 9120", "Lomas de Zamora", "active" ],
    [ "Casa Verde", "Paula Giménez", "Maipú 450", "Banfield", "active" ],
    [ "Lima Market", "Agustín Ferreyra", "Meeks 1350", "Temperley", "active" ],
    [ "Vera Home", "Carolina Díaz", "9 de Julio 300", "Lanús", "active" ],
    [ "Punto Natural", "Federico Álvarez", "Mitre 680", "Quilmes", "inactive" ]
  ].each_with_index do |(name, contact, address, city, status), index|
    south.customers.find_or_create_by!(name: name) do |customer|
      customer.assign_attributes(contact: contact, address: address, city: city, status: status,
        phone: "+54 11 5555-020#{index + 1}", email: "pedidos#{index + 1}@comercio.test")
    end
  end

  north.customers.find_or_create_by!(name: "Almacén del Norte") do |customer|
    customer.assign_attributes(contact: "Sofía López", address: "Belgrano 550", city: "Tigre", phone: "+54 11 5555-0301")
  end
end

Company.transaction do
  south = Company.find_by!(slug: "distribuidora-sur")
  north = Company.find_by!(slug: "distribuidora-norte")

  additional_customers = {
    south => [
      [ "Almacén San Martín", "María Fernández", "San Martín 123", "Adrogué", "active" ],
      [ "Autoservicio del Barrio", "Diego Castro", "Alsina 420", "Banfield", "active" ],
      [ "Mercado Central Sur", "Valentina Ruiz", "Av. San Martín 1850", "Lanús", "active" ],
      [ "Panadería La Espiga", "Javier Romero", "Av. Almirante Brown 780", "Temperley", "active" ]
    ],
    north => [
      [ "Dietética Natural", "Ana Martínez", "Av. Cazón 980", "Tigre", "active" ],
      [ "Autoservicio del Río", "Lucas García", "Av. del Libertador 1450", "San Fernando", "active" ],
      [ "Kiosco de la Estación", "Carla Torres", "Constitución 210", "San Fernando", "inactive" ],
      [ "Restaurante del Puerto", "Martín Suárez", "Paseo Victorica 320", "Tigre", "active" ],
      [ "Cafetería El Roble", "Sofía Molina", "Belgrano 810", "San Isidro", "active" ]
    ]
  }
  additional_customers.each do |company, customers|
    customers.each_with_index do |(name, contact, address, city, status), index|
      company.customers.find_or_create_by!(name: name) do |customer|
        customer.assign_attributes(contact: contact, address: address, city: city, status: status,
          phone: "+54 11 5555-04#{index.to_s.rjust(2, '0')}", email: "demo#{index + 1}@#{company.slug}.test")
      end
    end
  end

  driver_definitions = {
    south => [ [ "Juan Rodríguez", "repartidor.sur@repartos.test" ], [ "Camila Acosta", "camila.sur@repartos.test" ] ],
    north => [ [ "Diego López", "repartidor.norte@repartos.test" ], [ "Florencia Díaz", "florencia.norte@repartos.test" ] ]
  }
  drivers = driver_definitions.to_h do |company, definitions|
    records = definitions.map do |name, email|
      company.users.find_or_create_by!(email_address: email) do |user|
        user.assign_attributes(name: name, role: :driver, password: "Repartos-demo-2026")
      end
    end
    [ company, records ]
  end

  catalogs = {
    south => [
      [ "PAN-001", "Pan lactal", "pack", {} ],
      [ "PIZ-001", "Pizzetas x 6", "pack", { package_content_quantity: 6, package_content_unit: "unit" } ],
      [ "FAC-012", "Facturas por docena", "box", { package_content_quantity: 12, package_content_unit: "unit" } ],
      [ "HAR-025", "Harina bolsa 25 kg", "bag", { package_content_quantity: 25, package_content_unit: "kg" } ],
      [ "ALM-001", "Almendras a granel", "kg", {} ],
      [ "CHI-001", "Semillas de chía", "g", {} ],
      [ "ACE-001", "Aceite de girasol a granel", "l", {} ],
      [ "GAS-002", "Gaseosa de naranja 2 litros", "unit", { package_content_quantity: 2, package_content_unit: "l" } ],
      [ "AGU-006", "Agua mineral pack x 6", "pack", { package_content_quantity: 6, package_content_unit: "unit" } ],
      [ "GAL-012", "Galletitas surtidas caja x 12", "box", { package_content_quantity: 12, package_content_unit: "pack" } ],
      [ "LEC-001", "Leche entera 1 litro", "unit", { package_content_quantity: 1, package_content_unit: "l" } ],
      [ "PAN-RET", "Pan de salvado discontinuado", "pack", { active: false } ]
    ],
    north => [
      # The same SKU may identify a different product in another company.
      [ "PAN-001", "Pan integral con semillas", "pack", {} ],
      [ "NUE-001", "Nueces mariposa", "kg", {} ],
      [ "AVE-001", "Avena arrollada", "kg", {} ],
      [ "HAR-025", "Harina integral bolsa 25 kg", "bag", { package_content_quantity: 25, package_content_unit: "kg" } ],
      [ "MIX-001", "Mix de especias", "g", {} ],
      [ "ACE-001", "Aceite de oliva a granel", "l", {} ],
      [ "MIE-500", "Miel frasco 500 g", "unit", { package_content_quantity: 500, package_content_unit: "g" } ],
      [ "BAR-012", "Barritas de cereal caja x 12", "box", { package_content_quantity: 12, package_content_unit: "unit" } ],
      [ "SEM-005", "Semillas de girasol bolsa 5 kg", "bag", { package_content_quantity: 5, package_content_unit: "kg" } ],
      [ "TE-RET", "Té en hebras discontinuado", "bag", { active: false } ]
    ]
  }
  products = catalogs.to_h do |company, definitions|
    catalog = definitions.to_h do |sku, name, unit, attributes|
      product = company.products.find_or_create_by!(sku: sku) do |record|
        record.assign_attributes({ name: name, unit: unit }.merge(attributes))
      end
      [ sku, product ]
    end
    [ company.id, catalog ]
  end

  # Additional local records make the catalog and directory pagination easy to exercise.
  30.times do |index|
    number = (index + 1).to_s.rjust(2, "0")
    south.products.find_or_create_by!(sku: "DEMO-#{number}") do |product|
      product.assign_attributes(name: "Producto de prueba #{number}", unit: "unit", active: true)
    end
    south.customers.find_or_create_by!(external_code: "DEMO-#{number}") do |customer|
      customer.assign_attributes(name: "Comercio de prueba #{number}", address: "Calle de prueba #{index + 1}", city: "Adrogué", status: "active")
    end
  end

  seed_schedule = lambda do |company, customer_name, code, weekday, attributes, items|
    company.delivery_schedules.find_or_create_by!(notes: "Demo [#{code}]: entrega semanal.") do |schedule|
      schedule.assign_attributes({ customer: company.customers.find_by!(name: customer_name), weekday: weekday,
        starts_on: company.local_date - 8.weeks }.merge(attributes))
      items.each_with_index do |(sku, quantity, description, unit), index|
        product = products.fetch(company.id)[sku]
        schedule.delivery_schedule_items.build(product: product, quantity: quantity, position: index + 1,
          description: description || product&.name, unit: unit || product&.unit)
      end
    end
  end

  [
    [ south, "Casa Verde", "sur-lunes", 1, { window_start: "08:00", window_end: "12:00" }, [ [ "ALM-001", "10.500" ], [ "HAR-025", 2 ], [ "CHI-001", "250.125" ] ] ],
    [ south, "Almacén San Martín", "sur-martes-pan", 2, { preferred_time: "09:00" }, [ [ "PAN-001", 20 ], [ "LEC-001", 12 ] ] ],
    [ south, "Autoservicio del Barrio", "sur-martes-bebidas", 2, { window_start: "14:00", window_end: "17:00" }, [ [ "GAS-002", 24 ], [ "AGU-006", 5 ] ] ],
    [ south, "Lima Market", "sur-miercoles", 3, { preferred_time: "10:30" }, [ [ "GAL-012", 3 ], [ "ACE-001", "7.250" ] ] ],
    [ south, "Panadería La Espiga", "sur-jueves", 4, { window_start: "07:00", window_end: "10:00" }, [ [ "HAR-025", 4 ], [ nil, 2, "Harina especial a pedido", "bag" ] ] ],
    [ south, "Almacén San Martín", "sur-viernes-pizzetas", 5, { preferred_time: "18:00" }, [ [ "PIZ-001", 10 ] ] ],
    [ south, "Mercado Central Sur", "sur-viernes", 5, { window_start: "09:00", window_end: "13:00" }, [ [ "PAN-001", 30 ], [ "GAS-002", 48 ] ] ],
    [ south, "Farmacia Central", "sur-sabado", 6, { preferred_time: "09:30" }, [ [ "AGU-006", 3 ], [ "GAL-012", 2 ] ] ],
    [ south, "Vera Home", "sur-domingo", 7, {}, [ [ "FAC-012", 4 ], [ "LEC-001", 8 ] ] ],
    [ south, "Punto Natural", "sur-inactiva", 3, { preferred_time: "11:00", active: false }, [ [ "ALM-001", 5 ] ] ],
    [ north, "Dietética Natural", "norte-lunes", 1, { window_start: "08:00", window_end: "12:00" }, [ [ "NUE-001", "10.125" ], [ "HAR-025", 2 ] ] ],
    [ north, "Almacén del Norte", "norte-martes", 2, { preferred_time: "09:00" }, [ [ "PAN-001", 15 ], [ "MIE-500", 6 ] ] ],
    [ north, "Autoservicio del Río", "norte-miercoles", 3, { window_start: "13:00", window_end: "16:00" }, [ [ "BAR-012", 5 ], [ "SEM-005", 2 ] ] ],
    [ north, "Restaurante del Puerto", "norte-jueves", 4, { preferred_time: "08:30" }, [ [ "ACE-001", "12.750" ], [ "MIX-001", "500.250" ] ] ],
    [ north, "Cafetería El Roble", "norte-viernes", 5, { preferred_time: "07:30" }, [ [ "AVE-001", "4.500" ], [ "MIE-500", 4 ] ] ],
    [ north, "Dietética Natural", "norte-sabado", 6, { window_start: "09:00", window_end: "12:30" }, [ [ "NUE-001", "3.750" ], [ "SEM-005", 1 ] ] ],
    [ north, "Almacén del Norte", "norte-domingo", 7, {}, [ [ "PAN-001", 10 ], [ nil, "1.250", "Mezcla de frutos secos a pedido", "kg" ] ] ],
    [ north, "Kiosco de la Estación", "norte-inactiva", 2, { active: false }, [ [ "BAR-012", 1 ] ] ]
  ].each { |definition| seed_schedule.call(*definition) }

  [ south, north ].each do |company|
    Time.use_zone(company.time_zone) do
      [ [ -2, :completed ], [ -1, :completed ], [ 0, :in_progress ], [ 1, :assigned ], [ 2, :draft ], [ 3, :cancelled ] ].each_with_index do |(offset, status), index|
        date = company.local_date + offset
        # A separate namespace leaves existing user-generated runs untouched.
        key = "demo:v1:#{date}"
        next if company.delivery_runs.exists?(generation_key: key)

        driver = status == :draft ? nil : drivers.fetch(company)[index % drivers.fetch(company).size]
        run = company.delivery_runs.create!(generation_key: key, scheduled_date: date, name: "Demo · Reparto #{date.strftime('%d/%m/%Y')}", driver: driver)
        orders = DeliveryOrderGenerator.call(company: company, date: date)
        DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: status == :cancelled ? [] : orders.select { |order| order.pending? && order.visit_id.nil? }.map(&:id))

        generated_visits = run.visits.to_a

        # Manual visits demonstrate products outside the recurring catalog and
        # unsuccessful visits. Only newly created demo runs are populated.
        customer = company.customers.find_by!(name: company == south ? "Mercado Central Sur" : "Cafetería El Roble")
        position = run.visits.maximum(:position).to_i
        manual = run.visits.create!(company: company, customer: customer, position: position + 1,
          status: :pending,
          notes: status == :completed ? "Demo: visita cerrada o reprogramada por pedido del cliente." : "Demo: pedido manual adicional.")
        manual.delivery_items.create!(description: "Mezcla especial a pedido", unit: "kg", planned_quantity: "1.250")

        if status == :completed
          missed = run.visits.create!(company: company, customer: customer, position: position + 2,
            status: :pending, notes: "Demo: el cliente no atendió; no se entregó mercadería.")
          missed.delivery_items.create!(description: "Bulto adicional solicitado por teléfono", unit: "box", planned_quantity: 1, delivered_quantity: 0)
        end
        generated_visits.each_with_index do |visit, visit_index|
          next unless status == :completed || (status == :in_progress && visit_index.zero?)

          visit.delivery_items.each_with_index do |item, item_index|
            quantity = item.planned_quantity
            if visit_index.zero? && item_index.zero?
              quantity = if DeliveryUnits::DISCRETE.include?(item.unit)
                [ quantity - 2, 0 ].max
              else
                (quantity * BigDecimal("0.9")).round(3)
              end
              item.notes = "Demo: entrega parcial; el resto queda pendiente."
            end
            item.update!(delivered_quantity: quantity)
          end
          visit.update!(status: :completed, confirmed_by: driver, confirmed_at: date.in_time_zone.change(hour: 12), completed_at: date.in_time_zone.change(hour: 12))
        end

        if status == :completed
          manual.update!(status: offset == -2 ? :closed : :rescheduled, confirmed_by: driver, confirmed_at: date.in_time_zone.change(hour: 12))
          missed.update!(status: :not_attended, confirmed_by: driver, confirmed_at: date.in_time_zone.change(hour: 12))
        end
        run.update!(status: status)
      end
    end
  end

  [ south, north ].each do |company|
    puts "#{company.name}: #{company.customers.count} clientes, #{company.products.count} productos, #{company.delivery_schedules.count} programaciones, #{company.delivery_runs.count} repartos, #{company.visits.count} visitas."
  end
end

RoutingDemoSeeds.call
DemoOnboardingSeeds.call
