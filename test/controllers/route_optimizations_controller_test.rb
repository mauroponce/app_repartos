require "test_helper"
require_relative "../test_helpers/route_optimization_test_helper"

class RouteOptimizationsControllerTest < ActionDispatch::IntegrationTest
  include RouteOptimizationTestHelper
  setup { sign_in_as users(:one) }

  test "preview endpoint is read only and confirmation ignores unsigned route data" do
    order = optimization_order
    response = optimization_response({ users(:driver) => [ order ] })
    with_optimization_response(response) do
      assert_no_difference [ "DeliveryRun.count", "Visit.count" ] do
        post route_optimizations_path, params: { optimization: optimization_input([ order ]).except(:company) }, as: :json
        assert_response :success
      end
    end
    token = self.response.parsed_body["token"]
    assert token.present?
    assert_equal "no-store", self.response.headers["Cache-Control"]
    post create_optimized_delivery_runs_path, params: { proposal_token: token, delivery_run: { name: "Sur", status: "assigned" }, order_ids: [ -1 ], driver_id: users(:other_driver).id }
    assert_redirected_to delivery_runs_path(date: "2026-11-17")
    run = companies(:one).delivery_runs.last
    assert_equal users(:driver), run.driver
    assert_equal [ order.id ], run.delivery_orders.pluck(:id)
  end

  test "errors leave manual wizard usable and foreign identifiers are rejected" do
    order = optimization_order
    with_optimization_response do
      post route_optimizations_path, params: { optimization: optimization_input([ order ]).except(:company) }, as: :json
      assert_response :unprocessable_entity
      assert_equal "No disponible", response.parsed_body["error"]
    end
    post route_optimizations_path, params: { optimization: optimization_input([ order ], drivers: [ users(:other_driver) ]).except(:company) }, as: :json
    assert_response :not_found
    get new_delivery_run_path
    assert_response :success
    assert_select "fieldset[disabled] button", text: "Optimizar rutas"
    assert_select "input[name='delivery_run[name]']"
  end

  test "drivers cannot optimize or confirm routes" do
    sign_in_as users(:driver)
    post route_optimizations_path, params: { optimization: {} }, as: :json
    assert_response :forbidden
    post create_optimized_delivery_runs_path, params: { proposal_token: "forged" }
    assert_response :forbidden
  end
end
