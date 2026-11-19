require "test_helper"

class GeocodeCustomerJobTest < ActiveJob::TestCase
  test "reliable result is stored and Gemini is disabled" do
    customer = companies(:one).customers.create!(name: "Sin mapa", address: "Mitre 100", city: "Burzaco", location_verification: "pending")
    pipeline = Object.new
    def pipeline.call(*)
      { "precision" => "reliable", "candidate" => { "latitude" => -34.82, "longitude" => -58.38 } }
    end
    job = GeocodeCustomerJob.new
    assert_equal GeocodeCustomerJob::NullInterpreter, job.send(:pipeline, customer.company_id).instance_variable_get(:@gemini)
    job.define_singleton_method(:pipeline) { |_| pipeline }
    job.perform(customer.company_id, customer.id)
    assert_equal "reliable", customer.reload.location_verification
    assert customer.located?
  end

  test "ambiguous result leaves the customer unlocated" do
    customer = companies(:one).customers.create!(name: "Sin mapa", address: "Mitre 100", city: "Burzaco", location_verification: "pending")
    pipeline = Object.new
    def pipeline.call(*) = { "precision" => "ambiguous", "candidates" => [] }
    job = GeocodeCustomerJob.new
    job.define_singleton_method(:pipeline) { |_| pipeline }
    job.perform(customer.company_id, customer.id)
    assert_equal "ambiguous", customer.reload.geocoding_precision
    assert_not customer.located?
  end
end
