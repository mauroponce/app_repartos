raise "Onboarding fixtures require an isolated test database" unless Rails.env.test?

action, identifier = ARGV
if action == "bootstrap"
  slug = "onboarding-browser-#{SecureRandom.hex(6)}"
  admin = PlatformAdmin.create!(name: "Propietario E2E", email_address: "#{slug}@platform.test", password: "Onboarding-test-2026")
  today = Time.current.in_time_zone("America/Argentina/Buenos_Aires").to_date
  puts({ slug: slug, platform_email: admin.email_address, password: "Onboarding-test-2026", email: "#{slug}@admin.test",
    today: today, monday: today + ((1 - today.cwday) % 7) }.to_json)
  exit
end
raise "Unexpected fixture tenant" unless identifier.to_s.start_with?("onboarding-browser-")
company = Company.find_by(slug: identifier)
if action == "cleanup" && company.nil?
  PlatformAdmin.find_by(email_address: "#{identifier}@platform.test")&.destroy!
  puts({ cleaned: true }.to_json)
  exit
end
raise ActiveRecord::RecordNotFound unless company

case action
when "drain"
  # Never route these tests to a public provider, even with inherited host env.
  ENV["GEOREF_API_URL"] = "http://127.0.0.1:#{ENV.fetch('PWA_GEOCODING_PORT', '3198')}/georef"
  ENV["PHOTON_URL"] = "http://127.0.0.1:#{ENV.fetch('PWA_GEOCODING_PORT', '3198')}/photon"
  ENV["GEOREF_INTERVAL_MS"] = ENV["PHOTON_INTERVAL_MS"] = "0"
  ENV["GEMINI_ENABLED"] = "false"
  import = company.customer_imports.order(:id).last
  100.times do
    step = { "reading" => "read", "preparing" => "prepare", "processing" => "process", "importing" => "commit" }[import.reload.state]
    break unless step
    CustomerImportJob.perform_now(company.id, import.id, import.generation, step)
  end
  raise import.last_error.to_s unless import.state.in?(%w[mapping review completed])
  puts({ state: import.state }.to_json)
when "inspect"
  puts({ id: company.id, administrator: company.primary_administrator&.attributes&.slice("email_address", "role", "company_id"),
    customers: company.customers.order(:id).map { |customer| customer.attributes.slice("id", "name", "city", "address", "external_code", "latitude", "longitude", "location_verification").merge("routing" => customer.routing_location?) },
    products: company.products.order(:id).map { |product| product.attributes.slice("id", "sku", "name", "unit", "package_content_unit", "package_content_quantity") },
    imports: company.customer_imports.order(:id).map { |import| { id: import.id, summary: import.summary, state: import.state, precision: import.import_rows.group(:precision).count, review: import.import_rows.group(:review_state).count } },
    product_import_id: company.product_imports.order(:id).last&.id,
    drivers: company.users.driver.order(:id).map { |driver| driver.attributes.slice("id", "name", "email_address", "role", "status", "company_id") },
    schedules: company.delivery_schedules.order(:id).map { |schedule| { id: schedule.id, weekday: schedule.weekday, start: schedule.window_start&.strftime("%H:%M"), end: schedule.window_end&.strftime("%H:%M"), quantities: schedule.delivery_schedule_items.order(:position).pluck(:quantity) } },
    orders: company.delivery_orders.order(:id).map { |order| { id: order.id, date: order.scheduled_date, status: order.status, start: order.window_start&.strftime("%H:%M"), end: order.window_end&.strftime("%H:%M"), quantities: order.delivery_order_items.order(:position).pluck(:quantity) } },
    runs: company.delivery_runs.order(:id).map { |run| { id: run.id, driver_id: run.driver_id, name: run.name, date: run.scheduled_date, status: run.status, blocked: run.routing_blocked?,
      visits: run.visits.map { |visit| { id: visit.id, status: visit.status, position: visit.position, quantities: visit.delivery_items.order(:id).pluck(:planned_quantity), items: visit.delivery_items.order(:id).pluck(:id) } } } },
    operations: company.driver_sync_operations.pluck(:status) }.to_json)
when "cleanup"
  # This deletion is strictly limited to disposable browser-test tenants.
  company.update!(primary_administrator: nil)
  company.customer_imports.each { |import| import.source_file.purge; import.destroy! }
  [ RoutePublication, RoutingCacheEntry, RouteOptimizationProposal, IncidentPhoto, InternalNotice, WorkflowEvent, WorkflowCommand, WorkflowTask, CommercialOpportunity, Incident, CommercialRuleSetting,
    NotificationEvent, CustomerNotification, CommunicationConsent, DeliveryStatusEvent, DeliveryRunCost, RunStockMovement, DeliveryDispatchChange, DriverLocation,
    DriverSyncOperation, DeliveryItem, DeliveryOrderItem, DeliveryOrder, Visit, DeliveryRun, DeliveryScheduleItem, DeliverySchedule, ProductImport, Product, Customer,
    GeocodingCacheEntry ].each { |model| model.where(company: company).delete_all }
  Session.where(user_id: company.users.select(:id)).delete_all
  User.where(company: company).delete_all
  company.destroy!
  PlatformAdmin.find_by(email_address: "#{identifier}@platform.test")&.destroy!
  puts({ cleaned: true }.to_json)
end
