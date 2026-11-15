# Runs only via the browser test harness against local development/test data.
raise "Browser fixtures cannot run in production" if Rails.env.production?
action, identifier = ARGV
if action == "create"
  slug = "pwa-test-#{SecureRandom.hex(6)}"
  company = Company.create!(name: "PWA Browser Test", slug: slug)
  driver = company.users.create!(name: "Offline Test Driver", email_address: "#{slug}@example.test", role: :driver, password: "Offline-test-2026")
  customer = company.customers.create!(name: "Offline Test Customer", phone: "1234", address: "Mitre 123", city: "Adrogué")
  run = company.delivery_runs.new(name: "Prueba PWA offline", scheduled_date: company.local_date, driver: driver, status: :assigned)
  orders = 3.times.map do |index|
    company.delivery_orders.create!(customer: customer, scheduled_date: company.local_date, preferred_time: "#{9 + index}:00",
      delivery_order_items_attributes: [ { description: "Pan #{index}", unit: "pack", quantity: 20 } ])
  end
  DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: orders.map(&:id))
  puts({ company_id: company.id, user_id: driver.id, email: driver.email_address, password: "Offline-test-2026", run_id: run.id,
    visit_ids: run.visits.pluck(:id), item_ids: run.visits.map { |visit| visit.delivery_items.first.id } }.to_json)
elsif action == "operations"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-")
  manager = company.users.create!(name: "Dispatch Manager", email_address: "manager-#{company.slug}@example.test", role: :administrator, password: "Offline-test-2026")
  driver = company.users.create!(name: "Second Driver", email_address: "driver2-#{company.slug}@example.test", role: :driver, password: "Offline-test-2026")
  target = company.delivery_runs.create!(name: "Ruta de refuerzo", scheduled_date: company.local_date, driver: driver, status: :assigned)
  puts({ manager_email: manager.email_address, target_run_id: target.id, order_ids: company.delivery_orders.order(:id).pluck(:id), date: company.local_date }.to_json)
elsif action == "opportunities"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-")
  customer = company.customers.first
  [ 35, 40, 45, 50 ].each do |days|
    company.delivery_orders.create!(customer: customer, scheduled_date: company.local_date - days,
      delivery_order_items_attributes: [ { description: "Pedido histórico", unit: "pack", quantity: 10 } ])
  end
  company.create_commercial_rule_setting!(decline_min_orders: 3, decline_percent: 20)
  CommercialOpportunityDetector.new(company).call
  puts({ opportunity_id: company.commercial_opportunities.find_by!(rule: "decline").id }.to_json)
elsif action == "workflow_inspect"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-")
  puts({ incidents: company.incidents.order(:id).pluck(:id, :status), tasks: company.workflow_tasks.order(:id).pluck(:id, :status, :category),
    notices: company.internal_notices.order(:id).pluck(:id, :read_at, :acknowledged_at), commands: company.workflow_commands.count,
    photos: company.incident_photos.count, visits: company.visits.order(:id).pluck(:status), events: company.workflow_events.order(:id).pluck(:action) }.to_json)
elsif action == "replan"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-")
  orders = company.delivery_orders.order(:id).to_a
  DeliveryOrderEditor.call(order: orders[0], attributes: { delivery_order_items_attributes: [ { description: "Producto agregado", unit: "pack", quantity: 7 } ] })
  DeliveryOrderEditor.call(order: orders[1], attributes: { delivery_order_items_attributes: [ { id: orders[1].delivery_order_items.first.id, quantity: 25 } ] })
  DeliveryOrderEditor.call(order: orders[2], attributes: { delivery_order_items_attributes: [
    { id: orders[2].delivery_order_items.first.id, _destroy: true }, { description: "Producto reemplazado", unit: "pack", quantity: 9 }
  ] })
elsif action == "inspect"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-")
  puts({ operations: company.driver_sync_operations.order(:id).pluck(:status), visits: company.visits.order(:position).pluck(:status, :confirmed_by_id),
    quantities: DeliveryItem.where(company: company).order(:id).pluck(:delivered_quantity), orders: company.delivery_orders.order(:id).pluck(:status),
    evidence: company.delivery_evidences.order(:id).map { |file| { id: file.id, uuid: file.evidence_uuid, kind: file.kind, linked: file.driver_sync_operation_id.present?, attached: file.file.attached? } },
    receipts: company.visits.order(:position).pluck(:receipt_version, :failure_reason, :receiver_name, :recorded_latitude, :recorded_longitude),
    timings: company.visits.order(:position).pluck(:arrived_at, :unloading_started_at, :unloading_finished_at),
    stock_deliveries: company.run_stock_movements.where(kind: "delivery").count,
    final_events: company.delivery_status_events.where(to_status: "completed").where.not(visit_id: nil).count }.to_json)
elsif action == "revoke"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-")
  Session.where(user_id: company.users.select(:id)).delete_all
elsif action == "cleanup"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("pwa-test-")
  company.incident_photos.each { |photo| photo.file.purge }
  company.delivery_evidences.each { |evidence| evidence.file.purge; evidence.destroy! }
  [ RoutePublication, RoutingCacheEntry, RouteOptimizationProposal, IncidentPhoto, InternalNotice, WorkflowEvent, WorkflowCommand, WorkflowTask, CommercialOpportunity, Incident, CommercialRuleSetting, NotificationEvent, CustomerNotification, CommunicationConsent, DeliveryStatusEvent, DeliveryRunCost, RunStockMovement, DeliveryDispatchChange, DriverLocation, DriverSyncOperation, DeliveryItem, DeliveryOrderItem, DeliveryOrder, Visit, DeliveryRun ].each { |model| model.where(company: company).delete_all }
  Session.where(user_id: company.users.select(:id)).delete_all
  company.customers.delete_all(:delete_all)
  User.where(company: company).delete_all
  company.reload.destroy!
end
