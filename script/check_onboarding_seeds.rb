raise "Seed verification is development-only" unless Rails.env.development?
company = DemoOnboardingSeeds.call
snapshot = lambda do
  { company: company.reload.attributes, users: company.users.order(:id).pluck(:id, :name, :email_address, :password_digest, :role, :status),
    customers: company.customers.order(:id).pluck(:id, :external_code, :name, :latitude, :longitude, :location_verification),
    products: company.products.order(:id).pluck(:id, :sku), schedules: company.delivery_schedules.order(:id).pluck(:id),
    orders: company.delivery_orders.order(:id).pluck(:id, :scheduled_date, :status, :visit_id),
    runs: company.delivery_runs.order(:id).pluck(:id, :driver_id, :scheduled_date, :status, :generation_key),
    visits: company.visits.order(:id).pluck(:id, :status, :position) }
end
before = snapshot.call
DemoOnboardingSeeds.call
raise "Repeated seed changed identities, passwords, assignments or history" unless before == snapshot.call
puts({ seed_idempotency: "OK", company: company.name, customers: company.customers.count, products: company.products.count,
  drivers: company.users.driver.active.count, schedules: company.delivery_schedules.count, orders: company.delivery_orders.count,
  runs: company.delivery_runs.count, stops: company.visits.count, location_states: company.customers.group(:location_verification).count }.to_json)
