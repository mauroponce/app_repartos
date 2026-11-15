require "test_helper"
require_relative "../../test_helpers/single_route_test_helper"

class RouteCoverageTest < ActiveSupport::TestCase
  include SingleRouteTestHelper
  setup do
    @old_bounds = ENV["OSRM_COVERAGE_BBOX"]
    ENV["OSRM_COVERAGE_BBOX"] = "-59.10,-35.25,-57.65,-34.15"
  end
  teardown { ENV["OSRM_COVERAGE_BBOX"] = @old_bounds }

  test "coordinates outside the active bounding box fail before a network request" do
    calls = 0
    client = Osrm::Client.new(url: "http://osrm:5000", transport: ->(_uri) { calls += 1 })
    error = assert_raises(Osrm::Client::OutsideCoverage) { client.table([ [ -58.4, -34.8 ], [ -64.18, -31.42 ] ]) }
    assert_equal "Esta ubicación está fuera de la zona disponible para optimización", error.message
    assert_equal 0, calls
  end

  test "outside and missing locations prevent optimization while leaving manual planning valid" do
    run = single_route
    customer = run.visits.first.customer
    customer.update!(latitude: -31.42, longitude: -64.18)
    assert_raises(Osrm::Client::OutsideCoverage) { RouteOptimization::Problem.new(run.reload) }
    assert run.editable?
    ids = run.visits.pluck(:id)
    DeliveryRunReorderer.call(company: run.company, delivery_run: run, visit_ids: ids.reverse)
    assert_equal ids.reverse, run.visits.reload.pluck(:id)
    customer.update!(latitude: nil, longitude: nil)
    assert_match(/Falta la ubicación/, assert_raises(ArgumentError) { RouteOptimization::Problem.new(run.reload) }.message)
  end

  test "invalid coverage configuration fails closed without inventing a geographic area" do
    ENV["OSRM_COVERAGE_BBOX"] = "bad"
    assert_raises(Osrm::Client::Unavailable) { RouteOptimization::Dataset.coverage }
  end

  test "a ready preview from another version of the map cannot be applied" do
    run = single_route
    proposal = ready_single_proposal(run)
    proposal.update!(result: proposal.result.merge("dataset_identity" => "retired-map"))
    before = run.visits.pluck(:id)
    assert_match(/mapa cambió/, assert_raises(ArgumentError) { proposal.apply!(user: users(:one)) }.message)
    assert_equal before, run.visits.reload.pluck(:id)
  end
end
