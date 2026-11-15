module SingleRouteTestHelper
  def single_route(size: 3, **run_attributes)
    company = companies(:one)
    orders = size.times.map do |index|
      customer = company.customers.create!(name: "Parada #{index}", address: "Punto #{index}", city: "Adrogué", phone: "1234", latitude: -34.80 + index * 0.001, longitude: -58.39 + index * 0.001)
      company.delivery_orders.create!(customer: customer, scheduled_date: company.local_date, service_minutes: 5,
        delivery_order_items_attributes: [ { description: "Cajas", unit: "box", quantity: 4 }, { description: "Harina", unit: "kg", quantity: 2.5 } ])
    end
    run = company.delivery_runs.new({ name: "Ruta OSRM", scheduled_date: company.local_date, driver: users(:driver), status: :assigned }.merge(run_attributes))
    DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: orders.map(&:id))
    run
  end

  def single_client
    Object.new.tap do |client|
      client.define_singleton_method(:table) do |points|
        size = points.size
        matrix = Array.new(size) { |i| Array.new(size) { |j| i == j ? 0 : ((i + 1) % size == j ? 600 : 60) } }
        { durations: matrix, distances: matrix.map { |row| row.map { |v| v * 10 } } }
      end
      client.define_singleton_method(:route) do |points|
        { "distance" => 1000, "duration" => 120, "geometry" => { "type" => "LineString", "coordinates" => points }, "legs" => Array.new(points.size - 1) { { "distance" => 500, "duration" => 60 } } }
      end
    end
  end

  def ready_single_proposal(run, **settings)
    proposal = RouteOptimizationProposal.request!(user: users(:one), run: run, settings: settings)
    result = RouteOptimization::Problem.new(run.reload, settings: proposal.settings).calculate(client: single_client)
    proposal.update!(status: "ready", result: result)
    proposal
  end

  def with_single_client(client = single_client)
    original = Osrm::Client.method(:new)
    Osrm::Client.define_singleton_method(:new) { |**_args| client }
    yield
  ensure
    Osrm::Client.define_singleton_method(:new, original)
  end
end
