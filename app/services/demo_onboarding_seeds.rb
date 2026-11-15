class DemoOnboardingSeeds
  SLUG = "distribuidora-piloto-amba"
  PASSWORD = "Piloto-demo-2026"
  PLATFORM_EMAIL = "plataforma@repartos.test"
  PLATFORM_PASSWORD = "Plataforma-demo-2026"
  DRIVERS = [ [ "Juan Rodríguez", "juan@piloto.test" ], [ "Camila Fernández", "camila@piloto.test" ], [ "Martín López", "martin@piloto.test" ] ].freeze

  def self.call
    return unless Rails.env.development?

    Company.transaction do
      company = Company.find_or_create_by!(slug: SLUG) do |record|
        record.assign_attributes(name: "Distribuidora Piloto AMBA", province: "Buenos Aires", time_zone: "America/Argentina/Buenos_Aires", currency: "ARS")
      end
      created = company.previously_new_record?
      company.with_lock do
        # The complete scenario commits atomically. Once its immutable run keys
        # exist, leave every field alone, including edited notes, emails or SKUs.
        unless company.delivery_runs.where("generation_key LIKE ?", "onboarding:v1:%").exists?
          raise "La empresa demo ya no pertenece a Buenos Aires" unless company.province == "Buenos Aires"
          PlatformAdmin.find_or_create_by!(email_address: PLATFORM_EMAIL) do |admin|
            admin.assign_attributes(name: "Propietario demo", password: PLATFORM_PASSWORD)
          end
          new(company).populate(set_principal: created)
        end
      end
      company
    end
  end

  def initialize(company)
    @company = company
    @data = JSON.parse(File.read(Rails.root.join("docs/ejemplos/onboarding/datos_demo.json")))
  end

  def populate(set_principal: false)
    admin = user("Administración Piloto", "admin@piloto.test", :administrator)
    @company.update!(primary_administrator: admin) if set_principal
    drivers = DRIVERS.map { |name, email| user(name, email, :driver) }
    customers = @data.fetch("customers").each_with_index.map do |attributes, index|
      @company.customers.find_or_create_by!(external_code: attributes.fetch("external_code")) do |record|
        record.assign_attributes(attributes)
        record.location_verification = "pending"
        if index < 18
          # Synthetic training grid near AMBA sur. These points are explicitly
          # NOT the geocoding of the illustrative street addresses in the XLSX.
          record.assign_attributes(latitude: -34.79 - index / 6 * 0.015 - index % 3 * 0.002,
            longitude: -58.40 - index % 6 * 0.003, location_verification: "manual",
            contact: "DEMO: punto sintético, no geocodificación de la dirección")
        end
      end
    end
    products = @data.fetch("products").map do |attributes|
      @company.products.find_or_create_by!(sku: attributes.fetch("sku")) do |record|
        record.assign_attributes(attributes.merge("active" => true, "unit" => ProductImporter.normalize_unit(attributes["unit"]),
          "package_content_quantity" => attributes["package_content_quantity"].tr(",", ".").presence,
          "package_content_unit" => ProductImporter.normalize_unit(attributes["package_content_unit"])))
      end
    end
    # Choose once on initial population; subsequent calls retain the scenario.
    monday = @company.local_date + ((1 - @company.local_date.cwday) % 7)
    groups = [ [ 1, "08:00", "12:00", 0...6 ], [ 1, "14:00", "18:00", 6...12 ],
      [ 2, "08:00", "12:00", 12...18 ], [ 3, "09:00", "13:00", 18...20 ] ]
    groups.each_with_index do |(weekday, start_time, end_time, range), group|
      schedules = range.map do |index|
        @company.delivery_schedules.find_or_create_by!(notes: "Demo onboarding v1 · #{index + 1}") do |schedule|
          schedule.assign_attributes(customer: customers[index], weekday: weekday, starts_on: monday,
            window_start: start_time, window_end: end_time)
          [ [ products[index % products.size], 2 ], [ products[(index + 3) % products.size], 3 ] ].each_with_index do |(product, quantity), position|
            schedule.delivery_schedule_items.build(product: product, quantity: quantity, position: position + 1)
          end
        end
      end
      date = monday + weekday - 1
      missing = schedules.reject { |schedule| @company.delivery_orders.exists?(delivery_schedule_id: schedule.id, scheduled_date: date) }
      DeliveryOrderGenerator.call(company: @company, date: date, schedule_ids: missing.map(&:id)) if missing.any?
      next if group == 3 || @company.delivery_runs.exists?(generation_key: "onboarding:v1:#{group}")
      run = @company.delivery_runs.new(generation_key: "onboarding:v1:#{group}", name: "Demo · #{DeliverySchedule::WEEKDAYS[weekday]} #{start_time}–#{end_time}",
        scheduled_date: date, driver: drivers[group])
      orders = @company.delivery_orders.unplanned.where(delivery_schedule_id: schedules.map(&:id), scheduled_date: date)
      DeliveryRunPlanner.call(company: @company, delivery_run: run, order_ids: orders.pluck(:id))
      RoutePublication.use_manual!(user: admin, run: run)
    end
  end

  private

  def user(name, email, role)
    @company.users.find_or_create_by!(email_address: email) do |record|
      record.assign_attributes(name: name, password: PASSWORD, role: role, status: :active)
    end
  end
end
