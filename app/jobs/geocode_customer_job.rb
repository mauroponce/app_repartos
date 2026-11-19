class GeocodeCustomerJob < ApplicationJob
  queue_as :customer_imports
  limits_concurrency to: 1, key: ->(company_id, *) { "geocode-company-#{company_id}" }, duration: 10.minutes
  retry_on Geocoding::Deferred, Geocoding::Retryable, wait: :polynomially_longer, attempts: 5

  NullInterpreter = Object.new.tap { |object| def object.interpret(*) = nil }

  def perform(company_id, customer_id)
    customer = Customer.where(company_id: company_id).find_by(id: customer_id)
    return unless customer && !customer.located?
    address, city = customer.address, customer.city
    result = pipeline(company_id).call(
      { "address" => address, "city" => city, "province" => customer.company.province, "country" => "Argentina" })
    customer.reload
    return if customer.address != address || customer.city != city || customer.located?
    candidate = result["candidate"]
    if result["precision"] == "reliable" && candidate
      customer.update!(latitude: candidate.fetch("latitude"), longitude: candidate.fetch("longitude"),
        location_verification: "reliable", geocoding_precision: "reliable", geocoding_checked_at: Time.current)
    else
      customer.update!(geocoding_precision: result["precision"], geocoding_checked_at: Time.current)
    end
  end

  private

  def pipeline(company_id)
    Geocoding::Pipeline.new(company_id: company_id, gemini: NullInterpreter)
  end
end
