require "digest"

# Builds the same problem for preview and confirmation, so a changed order,
# location or driver invalidates a proposal before any delivery is assigned.
class RouteOptimizationProblem
  attr_reader :company, :date, :orders, :groups, :settings, :vehicles

  def initialize(company:, date:, order_ids:, settings:, lock: false)
    @company = company
    @date = Date.iso8601(date.to_s)
    ids = Array(order_ids).reject(&:blank?).map { |id| Integer(id.to_s, 10) }
    raise ArgumentError, "Seleccioná entre 1 y 500 pedidos, sin repetirlos" unless ids.size.in?(1..500) && ids.uniq.size == ids.size
    scope = company.delivery_orders.includes(:customer, :delivery_order_items).where(id: ids).order(:id)
    @orders = (lock ? scope.lock : scope).to_a
    raise ActiveRecord::RecordNotFound unless orders.size == ids.size
    unless orders.all? { |order| order.pending? && order.visit_id.nil? && order.scheduled_date == @date }
      raise ArgumentError, "Una entrega cambió o ya está planificada; revisá la selección"
    end
    if lock
      locations = company.customers.where(id: orders.map(&:customer_id)).order(:id).lock.index_by(&:id)
      orders.each { |order| order.customer = locations.fetch(order.customer_id) }
    end
    missing = orders.reject { |order| order.customer.routing_location? }
    raise ArgumentError, "Completá la ubicación de: #{missing.map(&:customer_name).uniq.join(', ')}" if missing.any?
    mismatched = orders.reject { |order| order.customer_address == [ order.customer.address, order.customer.city ].join(", ") }
    raise ArgumentError, "La dirección de una entrega cambió. Revisá su dirección antes de optimizar." if mismatched.any?
    @settings = normalize_settings(settings.deep_stringify_keys, lock: lock)
    RouteOptimization::Dataset.validate_coverage!([ @settings.fetch("depot"), *orders.map { |order| [ order.customer.longitude.to_f, order.customer.latitude.to_f ] } ])
    @groups = orders.group_by(&:planning_key).values.index_by { |rows| rows.first.id }
  end

  def fingerprint
    data = orders.map do |order|
      [ order.attributes, order.customer.attributes.slice("latitude", "longitude", "address", "city", "location_verification"), order.delivery_order_items.map(&:attributes) ]
    end
    Digest::SHA256.hexdigest(JSON.generate([ data, vehicles.map { |row| row[:driver].attributes.slice("id", "name", "status", "role") }, settings, date, company.province ]))
  end

  def payload(pins: {}, routes: nil)
    jobs = groups.map do |id, rows|
      order = rows.first
      job = { id: id, location: [ order.customer.longitude.to_f, order.customer.latitude.to_f ],
        delivery: [ rows.sum(&:load_units) ], service: rows.sum(&:service_minutes) * 60 }
      if order.preferred_time
        time = seconds(order.preferred_time)
        job[:time_windows] = [ [ time, time ] ]
      elsif order.window_start
        job[:time_windows] = [ [ seconds(order.window_start), seconds(order.window_end) ] ]
      end
      job
    end
    pins.each do |job_id, driver_id|
      id = Integer(job_id.to_s, 10)
      driver = Integer(driver_id.to_s, 10)
      raise ArgumentError, "La asignación fija no corresponde a la selección" unless groups.key?(id) && vehicles.any? { |row| row[:driver].id == driver }
      jobs.find { |job| job[:id] == id }[:skills] = [ driver ]
    end
    fleet = vehicles.map do |row|
      { id: row[:driver].id, start: settings["depot"], end: settings["depot"], capacity: [ row[:capacity] ],
        time_window: [ row[:start], row[:finish] ], skills: [ row[:driver].id ] }
    end
    if routes
      normalized = normalize_routes(routes)
      fleet.each do |vehicle|
        ids = normalized.find { |route| route["driver_id"] == vehicle[:id] }&.fetch("job_ids") || []
        vehicle[:steps] = [ { type: "start" }, *ids.map { |id| { type: "job", id: id } }, { type: "end" } ]
      end
    end
    { jobs: jobs, vehicles: fleet, options: { g: true, c: routes.present?, l: 20 } }
  end

  def normalize_routes(routes)
    rows = Array(routes).map do |route|
      route = route.to_h.stringify_keys
      { "driver_id" => Integer(route.fetch("driver_id").to_s, 10), "job_ids" => Array(route.fetch("job_ids")).map { |id| Integer(id.to_s, 10) } }
    end
    drivers = rows.map { |row| row["driver_id"] }
    jobs = rows.flat_map { |row| row["job_ids"] }
    unless drivers.uniq == drivers && (drivers - vehicles.map { |row| row[:driver].id }).empty? && jobs.sort == groups.keys.sort
      raise ArgumentError, "La propuesta debe incluir cada parada una sola vez y solo repartidores seleccionados"
    end
    rows
  rescue KeyError, TypeError
    raise ArgumentError, "La propuesta de rutas no es válida"
  end

  private

  def normalize_settings(input, lock:)
    depot = Array(input.fetch("depot")).map { |value| Float(value) }
    raise ArgumentError, "Ingresá coordenadas válidas para el depósito" unless depot.size == 2 && depot.all?(&:finite?) && depot[0].between?(-180, 180) && depot[1].between?(-90, 90)
    fleet = Array(input.fetch("vehicles"))
    raise ArgumentError, "Seleccioná entre 1 y 30 vehículos" unless fleet.size.in?(1..30)
    directory = company.users.driver.active
    if lock
      driver_ids = fleet.map { |entry| entry.to_h.stringify_keys.fetch("driver_id") }
      locked_drivers = directory.where(id: driver_ids).order(:id).lock.index_by { |driver| driver.id.to_s }
    end
    @vehicles = fleet.map do |entry|
      row = entry.to_h.stringify_keys
      driver = lock ? locked_drivers[row.fetch("driver_id").to_s] : directory.find(row.fetch("driver_id"))
      raise ActiveRecord::RecordNotFound unless driver
      capacity = Integer(row.fetch("capacity").to_s, 10)
      start = clock(row.fetch("start"))
      finish = clock(row.fetch("finish"))
      raise ArgumentError, "Revisá capacidad y jornada de cada vehículo" unless capacity.in?(1..1_000_000) && finish > start
      { driver: driver, capacity: capacity, start: start, finish: finish }
    end
    raise ArgumentError, "Usá un vehículo por repartidor en esta propuesta" unless vehicles.map { |row| row[:driver].id }.uniq.size == vehicles.size
    { "depot" => depot, "vehicles" => vehicles.map { |row| { "driver_id" => row[:driver].id, "capacity" => row[:capacity], "start" => format_clock(row[:start]), "finish" => format_clock(row[:finish]) } } }
  rescue KeyError, TypeError
    raise ArgumentError, "Completá depósito, capacidad y jornada de los vehículos"
  end

  def clock(value)
    raise ArgumentError, "Ingresá horarios válidos (HH:MM)" unless value.to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
    hours, minutes = value.split(":").map(&:to_i)
    hours * 3600 + minutes * 60
  end

  def format_clock(value)
    format("%02d:%02d", value / 3600, value % 3600 / 60)
  end

  def seconds(time)
    time.hour * 3600 + time.min * 60 + time.sec
  end
end
