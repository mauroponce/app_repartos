require "test_helper"
require_relative "../../test_helpers/single_route_test_helper"

class RouteOptimizationCacheTest < ActiveSupport::TestCase
  include SingleRouteTestHelper

  test "cache entries are isolated by company even for identical coordinates and keys" do
    key = Digest::SHA256.hexdigest("same-coordinates")
    first = RoutingCacheEntry.fetch(company: companies(:one), kind: "matrix", key: key) { { durations: [ [ 123 ] ] } }
    other = RoutingCacheEntry.fetch(company: companies(:two), kind: "matrix", key: key) { { durations: [ [ 456 ] ] } }
    hit = RoutingCacheEntry.fetch(company: companies(:one), kind: "matrix", key: key) { flunk "An unchanged matrix was recalculated" }
    assert_equal first, hit
    assert_not_equal first, other
    assert_equal 2, RoutingCacheEntry.count
  end

  test "a failed road response never leaves an empty cache entry" do
    assert_raises(Osrm::Client::Unavailable) do
      RoutingCacheEntry.fetch(company: companies(:one), kind: "matrix", key: "a" * 64) { raise Osrm::Client::Unavailable }
    end
    assert_equal 0, RoutingCacheEntry.count
  end

  test "unchanged route reuses matrices solutions and geometries without calling the solver or OSRM" do
    run = single_route
    client = single_client
    client.define_singleton_method(:cache_identity) { "known-test-map" }
    first = RouteOptimization::Problem.new(run.reload).calculate(client: client)
    %i[table route].each { |method| client.define_singleton_method(method) { |_| flunk "OSRM was queried again" } }
    original = RouteOptimization::Solver.instance_method(:call)
    RouteOptimization::Solver.define_method(:call) { raise "Solver was called again" }
    second = RouteOptimization::Problem.new(run.reload).calculate(client: client)
    assert_equal first, second
    assert_equal 1, RoutingCacheEntry.where(kind: "matrix").count
    assert_equal 1, RoutingCacheEntry.where(kind: "solution").count
  ensure
    RouteOptimization::Solver.define_method(:call, original) if original
  end

  test "without a known dataset version the client does not persist unsafe routing results" do
    run = single_route
    assert_no_difference "RoutingCacheEntry.count" do
      RouteOptimization::Problem.new(run).calculate(client: single_client)
    end
  end

  test "matrix indexes remain correct after reordering and include directed travel times" do
    run = single_route
    client = single_client
    client.define_singleton_method(:cache_identity) { "known-test-map" }
    first = RouteOptimization::Problem.new(run.reload).calculate(client: client)
    DeliveryRunReorderer.call(company: run.company, delivery_run: run, visit_ids: first[:proposed][:visit_ids])
    second = RouteOptimization::Problem.new(run.reload).calculate(client: client)
    assert_equal first[:proposed][:driving], second[:original][:driving]
    assert_equal first[:proposed][:distance], second[:original][:distance]
    assert_not second[:improved]
    assert_equal first[:proposed][:visit_ids], second[:proposed][:visit_ids]
  end

  test "retention only removes unused cache entries and preserves historical proposal results" do
    company = companies(:one)
    key = "a" * 64
    RoutingCacheEntry.fetch(company: company, kind: "matrix", key: key) { { durations: [ [ 0 ] ] } }
    RoutingCacheEntry.first.update_columns(last_used_at: 91.days.ago)
    run = single_route
    proposal = ready_single_proposal(run)
    result = proposal.result
    RouteProposalMaintenanceJob.perform_now(company.id)
    assert_equal 0, RoutingCacheEntry.count
    assert_equal result, proposal.reload.result
  end
end
