require "test_helper"
require_relative "../test_helpers/route_optimization_test_helper"
require_relative "../test_helpers/single_route_test_helper"

class CustomerImportRoutingTest < ActiveSupport::TestCase
  include RouteOptimizationTestHelper
  include SingleRouteTestHelper

  test "VROOM rejects supplied or pending coordinates before any external call" do
    customer = customers(:one)
    order = optimization_order
    %w[pending provided].each do |verification|
      customer.update!(location_verification: verification)
      error = assert_raises(ArgumentError) { RouteOptimizationProblem.new(**optimization_input([ order ])) }
      assert_includes error.message, "ubicación"
    end
    customer.update!(location_verification: "manual")
    assert RouteOptimizationProblem.new(**optimization_input([ order ]))
  end

  test "OSRM and visit navigation reject unverified points even when coordinates exist" do
    run = single_route
    customer = run.visits.first.customer
    customer.update!(location_verification: "provided")
    assert_not run.visits.first.reload.current_customer_location?
    error = assert_raises(ArgumentError) { RouteOptimization::Problem.new(run) }
    assert_includes error.message, "ubicación"
    customer.update!(location_verification: "manual")
    assert run.visits.first.reload.current_customer_location?
  end
end
