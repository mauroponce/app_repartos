# Synthetic test stops near town centres, never geocoded delivery addresses.
class RoutingDemoSeeds
  TOWNS = {
    "distribuidora-sur" => [ [ "Adrogué", -34.8008, -58.3907 ], [ "Burzaco", -34.8279, -58.3956 ], [ "Lomas de Zamora", -34.7612, -58.4006 ], [ "Banfield", -34.7435, -58.3955 ], [ "Temperley", -34.7744, -58.3825 ], [ "Lanús", -34.7077, -58.3915 ], [ "Quilmes", -34.7206, -58.2545 ], [ "Avellaneda", -34.6625, -58.3677 ] ],
    "distribuidora-norte" => [ [ "Tigre", -34.4260, -58.5796 ], [ "San Fernando", -34.4438, -58.5584 ], [ "San Isidro", -34.4706, -58.5132 ], [ "Martínez", -34.4896, -58.5002 ], [ "Vicente López", -34.5268, -58.4760 ], [ "Olivos", -34.5112, -58.4891 ], [ "Munro", -34.5310, -58.5257 ] ]
  }.freeze
  SCENARIOS = { "05" => 5, "10" => 10, "15" => 15, "25" => 25, "40" => 40, "ineficiente" => 15, "parcialmente-ordenada" => 15,
    "ventanas" => 10, "incompatible" => 5, "sin-coordenadas" => 5, "pedidos-agrupados" => 5, "coincidentes" => 5,
    "sin-deposito" => 10, "regreso-deposito" => 10, "finalizada" => 5 }.freeze

  def self.call
    return unless Rails.env.development?
    TOWNS.each do |slug, towns|
      company = Company.find_by(slug: slug)
      next unless company && company.users.exists?(email_address: slug == "distribuidora-sur" ? "admin@repartos.test" : "norte@repartos.test")
      company.with_lock do
        if company.depot_latitude.nil? && company.depot_longitude.nil?
          company.update!(depot_latitude: towns.first[1], depot_longitude: towns.first[2])
        end
        customers = towns.flat_map.with_index do |(town, latitude, longitude), town_index|
          6.times.map do |index|
            company.customers.find_or_create_by!(name: "Demo OSRM · #{town} #{index + 1}") do |customer|
              customer.assign_attributes(address: "Punto de prueba #{index + 1} (ubicación aproximada)", city: town,
                phone: "DEMO-#{town_index}-#{index}", latitude: latitude + (index % 3 - 1) * 0.002, longitude: longitude + (index / 3) * 0.002)
            end
          end
        end
        missing = company.customers.find_or_create_by!(name: "Demo OSRM · ubicación pendiente") do |customer|
          customer.assign_attributes(address: "Punto de prueba sin coordenadas", city: towns.first[0], phone: "DEMO-SIN-UBICACION")
        end
        driver = company.users.driver.active.order(:id).first
        product = company.products.where(active: true).order(:id).first
        SCENARIOS.each do |scenario, size|
          key = "demo:routing:v1:#{scenario}"
          next if company.delivery_runs.exists?(generation_key: key)
          date = company.local_date + 1
          run = company.delivery_runs.create!(name: "Demo OSRM · #{scenario} · #{size} paradas", scheduled_date: date, generation_key: key, driver: driver,
            routing_origin: scenario == "sin-deposito" ? "open" : "company", routing_return_to_depot: scenario == "regreso-deposito")
          selected = customers.first(size)
          selected = selected.each_slice(2).to_a.reverse.flatten if scenario == "ineficiente"
          selected = selected.sort_by(&:longitude) if scenario == "parcialmente-ordenada"
          selected[-1] = missing if scenario == "sin-coordenadas"
          selected = Array.new(size) { customers.first } if scenario == "coincidentes"
          orders = selected.each_with_index.map do |customer, index|
            attrs = { customer: customer, scheduled_date: date, service_minutes: 5 + index % 3 * 5,
              notes: "Escenario demostrativo OSRM #{scenario}. Coordenadas aproximadas; domicilio no verificado.",
              delivery_order_items_attributes: [ { product: product, description: product&.name || "Mercadería demo", unit: product&.unit || "box", quantity: index % 5 + 1 }, { description: "Bulto manual demo", unit: "box", quantity: 2 } ] }
            attrs.merge!(window_start: "08:00", window_end: scenario == "incompatible" ? "08:01" : "17:00") if scenario.in?(%w[ventanas incompatible])
            attrs[:preferred_time] = format("%02d:%02d", 9, index * 5) if scenario == "coincidentes"
            company.delivery_orders.create!(attrs)
          end
          if scenario == "pedidos-agrupados"
            extra = company.delivery_orders.create!(customer: selected.first, scheduled_date: date, service_minutes: 5,
              delivery_order_items_attributes: [ { description: "Segundo pedido en la misma visita", quantity: 3, unit: "pack" } ])
            orders << extra
          end
          DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: orders.map(&:id))
          if scenario == "finalizada"
            run.visits.each do |visit|
              visit.delivery_items.each { |item| item.update!(delivered_quantity: item.planned_quantity) }
              visit.update!(status: "completed", confirmed_by: driver, confirmed_at: date.in_time_zone.change(hour: 12), completed_at: date.in_time_zone.change(hour: 12))
            end
            run.update!(status: "completed")
          else
            run.update!(status: "assigned") if driver
          end
        end
      end
      puts "#{company.name}: escenarios OSRM disponibles; #{company.customers.count} clientes."
    end
  end
end
