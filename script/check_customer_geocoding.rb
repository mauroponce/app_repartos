# Optional live smoke check. Uses geocoding caches/quotas, never creates customers.
# COMPANY_ID=... ADDRESS='...' CITY='...' bin/rails runner script/check_customer_geocoding.rb
begin
  company = Company.find(Integer(ENV.fetch("COMPANY_ID"), 10))
address = ENV.fetch("ADDRESS")
context = { "city" => ENV["CITY"], "province" => ENV["PROVINCE"].presence || company.province, "country" => "Argentina" }.compact
result = Geocoding::Pipeline.new(company_id: company.id).call({ "address" => address }.merge(context), attempts: 2)
puts JSON.pretty_generate(result.slice("precision", "warnings").merge("candidate_count" => result["candidates"].size,
  "providers" => result["candidates"].map { |candidate| candidate["provider"] }.uniq))
rescue Geocoding::Deferred => error
  abort "Límite de consultas: reintentá en #{error.wait} segundos."
end
