raise "Customer import browser fixtures require an isolated test database" unless Rails.env.test?
action, identifier = ARGV
case action
when "create"
  company = Company.create!(name: "Prueba importación", slug: "import-browser-#{SecureRandom.hex(6)}")
  manager = company.users.create!(name: "Administrador", email_address: "admin-#{company.slug}@example.test", password: "Browser-import-2026", role: :administrator)
  puts({ company_id: company.id, email: manager.email_address, password: "Browser-import-2026" }.to_json)
when "drain"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("import-browser-")
  import = company.customer_imports.order(:id).last
  provider = Object.new
  provider.define_singleton_method(:search) do |address, **_|
    fixture = JSON.parse(File.read(Rails.root.join("test/fixtures/files/customer_imports/demonstration_states.json")))
    number = address["house_number"]
    key = { "450" => "reliable", "800" => "approximate", "1500" => "ambiguous" }[number]
    next [] unless key
    point = fixture.fetch(key).merge("street" => address["street"], "house_number" => number, "city" => address["city"], "label" => Geocoding::Address.query(address))
    result = [ point ]
    result << point.merge("provider" => "georef", "latitude" => -34.80) if key == "ambiguous"
    result
  end
  provider.define_singleton_method(:batch) { |addresses| addresses.map { |address| search(address) } }
  Geocoding::Georef.define_singleton_method(:new) { |**_| provider }
  Geocoding::Photon.define_singleton_method(:new) { |**_| provider }
  ai = Object.new
  ai.define_singleton_method(:interpret) { |_| nil }
  Geocoding::Gemini.define_singleton_method(:new) { |**_| ai }
  500.times do
    action = { "reading" => "read", "preparing" => "prepare", "processing" => "process", "importing" => "commit" }[import.reload.state]
    break unless action
    CustomerImportJob.perform_now(company.id, import.id, import.generation, action)
  end
  puts({ state: import.reload.state }.to_json)
when "inspect"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("import-browser-")
  puts({ customers: company.customers.order(:id).pluck(:name, :location_verification), orders: company.delivery_orders.count, runs: company.delivery_runs.count }.to_json)
when "cleanup"
  company = Company.find(identifier)
  raise "Unexpected fixture tenant" unless company.slug.start_with?("import-browser-")
  company.customer_imports.destroy_all
  Customer.where(company_id: company.id).delete_all
  company.users.destroy_all
  company.geocoding_cache_entries.delete_all if company.respond_to?(:geocoding_cache_entries)
  GeocodingCacheEntry.where(company_id: company.id).delete_all
  CommercialRuleSetting.where(company_id: company.id).delete_all
  company.destroy!
end
