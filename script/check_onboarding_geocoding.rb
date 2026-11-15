# Explicit, optional external integration; never included in CI or seeds.
abort "Usá EXTERNAL_GEOCODING_CHECK=1 fuera de CI/test." unless ENV["EXTERNAL_GEOCODING_CHECK"] == "1" && !ENV["CI"].present? && !Rails.env.test?
company = Company.find(ENV.fetch("COMPANY_ID"))
data = JSON.parse(File.read(Rails.root.join("docs/ejemplos/onboarding/datos_demo.json")))
pipeline = Geocoding::Pipeline.new(company_id: company.id)
results = data.fetch("customers").first(3).map do |customer|
  begin
    result = pipeline.call(customer.slice("address", "city").merge("province" => company.province), attempts: 2)
    { address: customer["address"], city: customer["city"], result: result }
  rescue Geocoding::Deferred => error
    # Record quota/rate limits; never spin, bypass limits or assume exactness.
    { address: customer["address"], city: customer["city"], deferred_seconds: error.wait }
  end
end
puts JSON.pretty_generate(checked_at: Time.current.iso8601, company_id: company.id,
  notice: "Direcciones ilustrativas: estos resultados externos requieren evaluación; no se modificó ningún cliente.", results: results)
