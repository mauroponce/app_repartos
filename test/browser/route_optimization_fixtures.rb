raise "Browser fixtures cannot run in production" if Rails.env.production?
action, identifier = ARGV
if action == "create"
  slug = "optimization-browser-#{SecureRandom.hex(6)}"
  company = Company.create!(name: "Optimization Browser Test", slug: slug)
  admin = company.users.create!(name: "Administrador", email_address: "#{slug}@example.test", role: :administrator, password: "Optimization-test-2026")
  drivers = %w[Juan Pedro].map { |name| company.users.create!(name: name, email_address: "#{name}-#{slug}@example.test", role: :driver, password: "Optimization-test-2026") }
  customers = %w[Almacén Kiosco].map do |name|
    company.customers.create!(name: name, phone: "1234", address: "Mitre 123", city: "Adrogué", latitude: -34.8, longitude: -58.34)
  end
  orders = customers.map.with_index do |customer, index|
    company.delivery_orders.create!(customer: customer, scheduled_date: company.local_date, preferred_time: "#{9 + index}:00",
      delivery_order_items_attributes: [ { description: "Cajones", unit: "box", quantity: 2 } ])
  end
  settings = { depot: [ -58.34, -34.8 ], vehicles: drivers.map { |driver| { driver_id: driver.id, capacity: 100, start: "08:00", finish: "18:00" } } }
  build = lambda do |assignments|
    response = { "code" => 0, "summary" => { "violations" => [] }, "unassigned" => [], "routes" => assignments.map do |driver, jobs|
      { "vehicle" => driver.id, "geometry" => "_p~iF~ps|U_ulLnnqC_mqNvxq`@", "distance" => 5000, "duration" => 1200, "violations" => [],
        "steps" => [ { "type" => "start", "arrival" => 28800 }, *jobs.map { |order| { "type" => "job", "id" => order.id, "arrival" => order.preferred_time.seconds_since_midnight.to_i, "waiting_time" => 0 } }, { "type" => "end", "arrival" => 61200 } ] }
    end }
    client = Object.new
    client.define_singleton_method(:call) { |_payload| response }
    DeliveryRouteOptimizer.call(company: company, date: company.local_date, order_ids: orders.map(&:id), settings: settings, client: client)
  end
  initial = build.call({ drivers[0] => [ orders[0] ], drivers[1] => [ orders[1] ] })
  # Moving the first stop to Pedro appends it after his original stop.
  adjusted = build.call({ drivers[1] => [ orders[1], orders[0] ] })
  puts({ company_id: company.id, email: admin.email_address, password: "Optimization-test-2026", date: company.local_date, driver_ids: drivers.map(&:id),
    order_ids: orders.map(&:id), initial: initial, adjusted: adjusted }.to_json)
elsif action == "inspect"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("optimization-browser-")
  puts({ runs: company.delivery_runs.order(:id).map { |run| { driver_id: run.driver_id, order_ids: run.delivery_orders.order("visits.position").pluck(:id) } } }.to_json)
elsif action == "cleanup"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("optimization-browser-")
  [ RoutePublication, RoutingCacheEntry, RouteOptimizationProposal, IncidentPhoto, InternalNotice, WorkflowEvent, WorkflowCommand, WorkflowTask, CommercialOpportunity, Incident, CommercialRuleSetting, DeliveryStatusEvent, DeliveryRunCost, RunStockMovement, DeliveryItem, DeliveryOrderItem, DeliveryOrder, Visit, DeliveryRun ].each { |model| model.where(company: company).delete_all }
  Session.where(user_id: company.users.select(:id)).delete_all
  company.customers.delete_all(:delete_all)
  User.where(company: company).delete_all
  company.destroy!
end
