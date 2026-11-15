raise "Browser fixtures cannot run in production" if Rails.env.production?
action, identifier = ARGV
if action == "create"
  slug = "pwa-test-single-route-#{SecureRandom.hex(6)}"
  company = Company.create!(name: "Single Route Browser Test", slug: slug)
  manager = company.users.create!(name: "Administrador", email_address: "manager-#{slug}@example.test", role: :administrator, password: "Routes-test-2026")
  driver = company.users.create!(name: "Repartidor", email_address: "driver-#{slug}@example.test", role: :driver, password: "Routes-test-2026")
  points = [ [ -58.3816, -34.6037 ], [ -58.435, -34.609 ], [ -58.39, -34.606 ], [ -58.44, -34.601 ], [ -58.40, -34.61 ] ]
  orders = points.each_with_index.map do |(longitude, latitude), index|
    customer = company.customers.create!(name: "Parada OSRM #{index + 1}", address: "Punto aproximado #{index + 1}", city: "Buenos Aires", phone: "DEMO", latitude: latitude, longitude: longitude)
    company.delivery_orders.create!(customer: customer, scheduled_date: company.local_date, service_minutes: 5,
      delivery_order_items_attributes: [ { description: "Caja", unit: "box", quantity: 3 }, { description: "Harina", unit: "kg", quantity: 2.5 } ])
  end
  run = company.delivery_runs.new(name: "Prueba de optimización vial", scheduled_date: company.local_date, driver: driver, status: :assigned)
  DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: orders.map(&:id))
  puts({ company_id: company.id, run_id: run.id, manager_email: manager.email_address, driver_email: driver.email_address, password: "Routes-test-2026",
    original_ids: run.visits.pluck(:id), orders: orders.map { |order| order.reload.attributes }, items: company.delivery_items.order(:id).map(&:attributes) }.to_json)
elsif action.in?(%w[calculate publish])
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-single-route-")
  PrepareRoutePublicationJob.perform_now(company.id, company.delivery_runs.sole.id) if action == "publish"
  proposal = company.route_optimization_proposals.order(:id).last!
  client = Object.new
  client.define_singleton_method(:table) do |points|
    size = points.size
    matrix = Array.new(size) { |i| Array.new(size) { |j| i == j ? 0 : ((i + 1) % size == j ? 600 : 60) } }
    { durations: matrix, distances: matrix.map { |row| row.map { |value| value * 10 } } }
  end
  client.define_singleton_method(:route) { |points| { "geometry" => { "type" => "LineString", "coordinates" => points } } }
  if action == "publish"
    original = Osrm::Client.method(:new)
    begin
      Osrm::Client.define_singleton_method(:new) { |**_args| client }
      OptimizeDeliveryRunJob.perform_now(company.id, proposal.id)
    ensure
      Osrm::Client.define_singleton_method(:new, original)
    end
  else
    proposal.update!(status: "ready", error_message: nil, result: RouteOptimization::Problem.new(proposal.delivery_run, settings: proposal.settings).calculate(client: client))
  end
elsif action == "inspect"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-single-route-")
  proposal = company.route_optimization_proposals.order(:id).last!
  puts({ status: proposal.status, proposed_ids: proposal.result.dig("proposed", "visit_ids"), actual_ids: proposal.delivery_run.visits.pluck(:id),
    orders: company.delivery_orders.order(:id).map(&:attributes), items: company.delivery_items.order(:id).map(&:attributes) }.to_json)
else
  load Rails.root.join("test/browser/fixtures.rb")
end
