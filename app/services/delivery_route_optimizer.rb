class DeliveryRouteOptimizer
  class InvalidResponse < VroomClient::Error; end

  def self.call(company:, date:, order_ids:, settings:, pins: {}, routes: nil, client: VroomClient.new)
    problem = RouteOptimizationProblem.new(company: company, date: date, order_ids: order_ids, settings: settings)
    fingerprint = problem.fingerprint
    payload = problem.payload(pins: pins, routes: routes)
    result = client.call(payload)
    proposal = new(problem, result, payload).proposal
    pins.each do |job_id, driver_id|
      assigned = proposal["routes"].find { |route| route["job_ids"].include?(Integer(job_id.to_s, 10)) }
      raise InvalidResponse, "El optimizador no respetó una asignación fija" if assigned && assigned["driver_id"] != Integer(driver_id.to_s, 10)
    end
    if routes
      expected = problem.normalize_routes(routes).reject { |route| route["job_ids"].empty? }.sort_by { |route| route["driver_id"] }
      actual = proposal["routes"].map { |route| route.slice("driver_id", "job_ids") }.sort_by { |route| route["driver_id"] }
      raise InvalidResponse, "El optimizador no respetó el orden manual" unless actual == expected
    end
    if proposal["unassigned"].empty? && proposal["violations"].empty?
      proposal["token"] = verifier.generate({ "company_id" => company.id, "key" => SecureRandom.uuid,
        "date" => problem.date.iso8601, "order_ids" => problem.orders.map(&:id), "settings" => problem.settings,
        "fingerprint" => fingerprint, "routes" => proposal["routes"] }, purpose: :route_proposal, expires_in: 30.minutes)
    end
    proposal
  end

  def self.verifier
    Rails.application.message_verifier("delivery-route-optimization")
  end

  def initialize(problem, result, payload)
    @problem, @result = problem, result
    @jobs = payload[:jobs].index_by { |job| job[:id] }
  end

  def proposal
    raise InvalidResponse, "La respuesta del optimizador está incompleta" unless @result["routes"].is_a?(Array) && @result["unassigned"].is_a?(Array)
    seen_jobs, seen_drivers = [], []
    violations = []
    routes = @result["routes"].filter_map do |route|
      vehicle = @problem.vehicles.find { |row| row[:driver].id == route["vehicle"] }
      raise InvalidResponse, "El optimizador devolvió un vehículo desconocido o repetido" unless vehicle && !seen_drivers.include?(route["vehicle"])
      seen_drivers << route["vehicle"]
      steps = route.fetch("steps")
      raise InvalidResponse, "El optimizador devolvió paradas inválidas" unless steps.is_a?(Array) && steps.first&.fetch("type") == "start" && steps.last&.fetch("type") == "end"
      jobs = steps.select { |step| step["type"] == "job" }
      # Plan mode also returns unused vehicles with start/end but no geometry.
      next if jobs.empty? && steps.size == 2
      ids = jobs.map { |step| step.fetch("id") }
      seen_jobs.concat(ids)
      violations.concat(Array(route["violations"]))
      steps.each { |step| violations.concat(Array(step["violations"])) }
      # Do not accept a response without road geometry or travel indicators.
      raise InvalidResponse, "El optimizador no devolvió el recorrido sobre calles" unless route["geometry"].is_a?(String) && route["geometry"].present?
      distance = nonnegative_integer(route.fetch("distance"))
      duration = nonnegative_integer(route.fetch("duration"))
      start = nonnegative_integer(steps.first.fetch("arrival"))
      finish = nonnegative_integer(steps.last.fetch("arrival"))
      load = ids.sum { |id| @problem.groups.fetch(id).sum(&:load_units) }
      violations << { "cause" => "load" } if load > vehicle[:capacity]
      violations << { "cause" => "delay" } if start < vehicle[:start] || finish > vehicle[:finish]
      stops = jobs.map do |step|
        rows = @problem.groups.fetch(step["id"])
        arrival = nonnegative_integer(step.fetch("arrival"))
        waiting = nonnegative_integer(step.fetch("waiting_time", 0))
        service_start = arrival + waiting
        time_window = @jobs.fetch(step["id"])[:time_windows]&.first
        violations << { "cause" => "delay" } if time_window && !service_start.between?(*time_window)
        { "id" => step["id"], "order_ids" => rows.map(&:id), "customer" => rows.first.customer_name,
          "address" => rows.first.customer_address, "arrival" => service_start, "load_units" => rows.sum(&:load_units),
          "service_minutes" => rows.sum(&:service_minutes) }
      end
      { "driver_id" => vehicle[:driver].id, "driver_name" => vehicle[:driver].name, "capacity" => vehicle[:capacity],
        "job_ids" => ids, "order_ids" => stops.flat_map { |stop| stop["order_ids"] }, "stops" => stops,
        "distance" => distance, "duration" => duration, "start" => start, "finish" => finish, "load_units" => load, "geometry" => route["geometry"] }
    end
    unassigned = @result["unassigned"].map do |job|
      id = job.fetch("id")
      seen_jobs << id
      rows = @problem.groups.fetch(id)
      { "id" => id, "order_ids" => rows.map(&:id), "customer" => rows.first.customer_name, "address" => rows.first.customer_address,
        "load_units" => rows.sum(&:load_units), "service_minutes" => rows.sum(&:service_minutes) }
    end
    raise InvalidResponse, "El optimizador omitió o repitió entregas" unless seen_jobs.sort == @problem.groups.keys.sort
    violations.concat(Array(@result.dig("summary", "violations")))
    { "routes" => routes, "unassigned" => unassigned, "violations" => violations.map { |row| row.fetch("cause") }.uniq,
      "vehicles" => @problem.vehicles.map { |row| { "driver_id" => row[:driver].id, "name" => row[:driver].name, "capacity" => row[:capacity] } } }
  rescue KeyError, TypeError, NoMethodError, ArgumentError
    raise InvalidResponse, "El optimizador devolvió una propuesta inválida"
  end

  private

  def nonnegative_integer(value)
    raise InvalidResponse, "El optimizador devolvió métricas inválidas" unless value.is_a?(Integer) && value >= 0
    value
  end
end
