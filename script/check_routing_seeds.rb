raise "Seed verification is development-only" unless Rails.env.development?
load Rails.root.join("db/seeds.rb")
slugs = RoutingDemoSeeds::TOWNS.keys
counts = -> { Company.where(slug: slugs).order(:id).map { |company| [ company.id, company.customers.count, company.delivery_runs.count, company.visits.count, company.delivery_orders.count, company.delivery_items.count ] } }
first = counts.call
load Rails.root.join("db/seeds.rb")
raise "Repeated seeds changed record counts" unless first == counts.call
Company.where(slug: slugs).find_each do |company|
  runs = company.delivery_runs.where("generation_key LIKE ?", "demo:routing:v1:%")
  raise "Missing scenarios" unless runs.count == RoutingDemoSeeds::SCENARIOS.size
  expected = RoutingDemoSeeds::SCENARIOS.keys - %w[sin-coordenadas finalizada]
  expected.each do |scenario|
    run = runs.find_by!(generation_key: "demo:routing:v1:#{scenario}")
    raise "Missing valid coordinates" unless run.visits.all? { |visit| visit.customer.located? }
  end
end
puts({ seed_idempotency: "OK", companies: counts.call }.to_json)
