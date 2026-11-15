module RouteOptimization
  class Problem
    MAX_STOPS = 100
    attr_reader :run, :company, :settings, :visits, :coordinates, :stops, :depot_index

    def initialize(run, settings: {})
      @run, @company = run, run.company
      raise ArgumentError, "La hoja ya no admite optimización porque tiene ejecución o está finalizada" unless run.editable?
      @visits = run.visits.includes(:customer, :delivery_schedule, :delivery_items, delivery_orders: :delivery_order_items).to_a
      raise ArgumentError, "La optimización admite entre 1 y #{MAX_STOPS} paradas" unless visits.size.in?(1..MAX_STOPS)
      @settings = normalize_settings(settings.stringify_keys)
      @coordinates = []
      @depot_index = nil
      if @settings["origin"] == "depot"
        raise ArgumentError, "Configurá las coordenadas del depósito antes de utilizarlo" unless company.depot_latitude && company.depot_longitude
        @depot_index = 0
        coordinates << [ company.depot_longitude.to_f, company.depot_latitude.to_f ]
      end
      @stops = visits.map do |visit|
        customer = visit.customer
        raise ArgumentError, "Falta la ubicación de #{visit.customer_name}" unless customer.located?
        unless visit.customer_address == [ customer.address, customer.city ].compact.join(", ")
          raise ArgumentError, "La dirección histórica de #{visit.customer_name} difiere de su ubicación actual. Revisá la parada antes de optimizar."
        end
        index = coordinates.size
        coordinates << [ customer.longitude.to_f, customer.latitude.to_f ]
        orders = visit.delivery_orders.to_a
        schedules = orders.empty? ? [ visit.delivery_schedule ].compact : orders
        starts = schedules.filter_map { |order| seconds(order.window_start) }
        finishes = schedules.filter_map { |order| seconds(order.window_end) }
        preferred = schedules.filter_map { |order| seconds(order.preferred_time) }
        { id: visit.id, index: index, window_start: starts.max, window_end: finishes.min, preferred: preferred.first,
          service: orders.any? ? orders.sum(&:service_minutes) * 60 : company.routing_service_minutes * 60 }
      end
      Dataset.validate_coverage!(coordinates)
    end

    def fingerprint
      snapshot = [ run.attributes, company.attributes.slice("time_zone", "depot_latitude", "depot_longitude", "routing_departure", "routing_return_to_depot", "routing_preferred_tolerance", "routing_service_minutes"),
        settings, visits.map { |visit| [ visit.attributes, visit.customer.attributes.slice("id", "latitude", "longitude", "address", "city", "updated_at"), visit.delivery_schedule&.attributes, visit.delivery_items.map(&:attributes), visit.delivery_orders.sort_by(&:id).map { |order| [ order.attributes, order.delivery_order_items.map(&:attributes) ] } ] } ]
      Digest::SHA256.hexdigest(JSON.generate(canonical(snapshot)))
    end

    def calculate(client: Osrm::Client.new)
      RoutingCacheEntry.transaction(requires_new: true) { calculate_with_cache(client: client) }
    end

    def calculate_with_cache(client:)
      identity = client.cache_identity if client.respond_to?(:cache_identity)
      matrix = road_matrix(client, identity)
      solver = Solver.new(stops: stops, **matrix, departure: clock(settings.fetch("departure")), depot_index: depot_index,
        return_to_depot: settings.fetch("return_to_depot"), tolerance: company.routing_preferred_tolerance * 60)
      result = cached("solution", calculation_key(dataset: identity), identity) { solver.call.except(:original) }
      original = solver.evaluate(stops)
      proposed = solver.evaluate(result.fetch(:proposed).fetch(:visit_ids).map { |id| stops.find { |stop| stop[:id] == id } })
      improved = (solver.score(proposed) <=> solver.score(original)) == -1
      result = result.merge(original: original, proposed: improved ? proposed : original, improved: improved)
      [ :original, :proposed ].each do |key|
        row = result[key]
        next unless row[:feasible]
        points = row[:visit_ids].map { |id| coordinates[stops.find { |stop| stop[:id] == id }.fetch(:index)] }
        points.unshift(coordinates[depot_index]) if depot_index
        points << coordinates[depot_index] if settings["return_to_depot"]
        row[:geometry] = cached("geometry", points, identity) { client.route(points).fetch("geometry") }.deep_stringify_keys if points.size > 1
      end
      raise Osrm::Client::Unavailable, "El mapa cambió durante el cálculo; solicitá otra optimización" if client.respond_to?(:cache_identity) && client.cache_identity != identity
      result.merge(dataset_identity: identity, origin: settings["origin"], return_to_depot: settings["return_to_depot"], preferred_tolerance: company.routing_preferred_tolerance,
        savings_distance: (result[:original][:distance] - result[:proposed][:distance]).round(2), savings_driving: (result[:original][:driving] - result[:proposed][:driving]).round(2))
    end

    # Routing identity excludes names, prices, quantities and technical dates.
    # Positions are excluded too: the current order is cheaply evaluated again
    # against the stored candidate, retaining the manual order on a tie.
    def calculation_key(dataset: Dataset.identity)
      rows = stops.sort_by { |stop| stop[:id] }.map { |stop| stop.except(:index).merge(coordinate: coordinates[stop[:index]]) }
      Digest::SHA256.hexdigest(JSON.generate(canonical([ "solver-v1", dataset, rows, company.time_zone, run.scheduled_date,
        clock(settings.fetch("departure")), settings["return_to_depot"], depot_index && coordinates[depot_index], company.routing_preferred_tolerance ])))
    end

    private

    private :calculate_with_cache

    def road_matrix(client, identity)
      return { durations: [ [ 0 ] ], distances: [ [ 0 ] ] } if coordinates.size == 1
      canonical_points = coordinates.sort
      matrix = cached("matrix", canonical_points, identity) { client.table(canonical_points) }
      indexes = coordinates.map { |point| canonical_points.index(point) }
      matrix.transform_values { |rows| indexes.map { |i| indexes.map { |j| rows[i][j] } } }
    end

    def cached(kind, payload, identity)
      return yield unless identity
      key = Digest::SHA256.hexdigest(JSON.generate(canonical([ identity, payload ])))
      RoutingCacheEntry.fetch(company: company, kind: kind, key: key) { yield }
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
      when Array then value.map { |entry| canonical(entry) }
      when Time, ActiveSupport::TimeWithZone then value.getutc.iso8601(6)
      when Date then value.iso8601
      when BigDecimal then value.to_s("F")
      else value
      end
    end

    def normalize_settings(input)
      origin = input["origin"].presence || (run.routing_origin == "open" || company.depot_latitude.nil? ? "open" : "depot")
      raise ArgumentError, "Elegí recorrido abierto o salida desde el depósito" unless origin.in?(%w[open depot])
      back = if input.key?("return_to_depot")
        ActiveModel::Type::Boolean.new.cast(input["return_to_depot"])
      else
        run.routing_return_to_depot.nil? ? (run.routing_origin == "open" ? false : company.routing_return_to_depot) : run.routing_return_to_depot
      end
      raise ArgumentError, "El regreso requiere salida desde un depósito" if back && origin != "depot"
      departure = input["departure"].presence || company.routing_departure
      clock(departure)
      { "origin" => origin, "return_to_depot" => !!back, "departure" => departure }
    end

    def clock(value)
      raise ArgumentError, "La hora de salida debe tener formato HH:MM" unless value.to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
      hour, minute = value.split(":").map(&:to_i)
      local_seconds(hour, minute, 0)
    end

    def seconds(value)
      local_seconds(value.hour, value.min, value.sec) if value
    end

    def local_seconds(hour, minute, second)
      zone = ActiveSupport::TimeZone[company.time_zone]
      day = run.scheduled_date
      wall_clock = Time.utc(day.year, day.month, day.day, hour, minute, second)
      unless zone.tzinfo.periods_for_local(wall_clock).one?
        raise ArgumentError, "Un horario es ambiguo o no existe en esa fecha por el cambio de hora. Elegí un horario sin esa ambigüedad."
      end
      local = zone.local(day.year, day.month, day.day, hour, minute, second)
      (local - zone.local(day.year, day.month, day.day)).to_f
    end
  end
end
