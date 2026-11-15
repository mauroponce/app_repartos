require "test_helper"
require_relative "../test_helpers/single_route_test_helper"

class RoutePublicationsControllerTest < ActionDispatch::IntegrationTest
  include SingleRouteTestHelper
  setup { @run = single_route(status: :draft); sign_in_as users(:one) }

  test "admin confirms immediately and sees a background publication status" do
    post delivery_run_route_publication_path(@run)
    assert_redirected_to delivery_run_path(@run)
    assert_equal "draft", @run.reload.status
    assert_equal "pending", @run.route_publication.state
    get delivery_run_path(@run)
    assert_select "h2", text: "Preparando recorrido"
    get delivery_run_route_publication_path(@run)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "pending", response.parsed_body["state"]
  end

  test "driver download excludes a route awaiting the definitive order" do
    @run.update!(status: :assigned)
    post delivery_run_route_publication_path(@run)
    sign_in_as users(:driver)
    get "/repartidor/api/v1/work"
    assert_response :success
    assert_not_includes response.parsed_body["packages"].map { |row| row["id"] }, @run.id
    get repartidor_root_path
    assert_response :success
    assert_select ".delivery-item[data-visit-id]", count: 0
  end

  test "driver receives the definitive order only after background completion" do
    post delivery_run_route_publication_path(@run)
    PrepareRoutePublicationJob.perform_now(@run.company_id, @run.id)
    proposal = @run.reload.route_publication.proposal
    with_single_client { OptimizeDeliveryRunJob.perform_now(@run.company_id, proposal.id) }
    sign_in_as users(:driver)
    get "/repartidor/api/v1/work"
    package = response.parsed_body["packages"].find { |row| row["id"] == @run.id }
    assert_equal proposal.reload.result.dig("proposed", "visit_ids"), package.fetch("visits").map { |row| row["id"] }
  end

  test "explicit manual publication bypasses a pending calculation without dropping orders" do
    post delivery_run_route_publication_path(@run)
    original = @run.visits.pluck(:id)
    post manual_delivery_run_route_publication_path(@run)
    assert_redirected_to delivery_run_path(@run)
    assert_equal "manual", @run.reload.route_publication.state
    assert_equal "assigned", @run.status
    assert_equal original, @run.visits.pluck(:id)
  end

  test "viewing a completed calculation repeatedly does not enqueue computation" do
    post delivery_run_route_publication_path(@run)
    PrepareRoutePublicationJob.perform_now(@run.company_id, @run.id)
    with_single_client { OptimizeDeliveryRunJob.perform_now(@run.company_id, @run.reload.route_publication.proposal_id) }
    assert_no_enqueued_jobs(only: [ PrepareRoutePublicationJob, OptimizeDeliveryRunJob ]) do
      2.times { get delivery_run_path(@run); assert_response :success }
    end
  end

  test "another company cannot confirm inspect or publish the route" do
    sign_in_as users(:two)
    post delivery_run_route_publication_path(@run)
    assert_response :not_found
    get delivery_run_route_publication_path(@run)
    assert_response :not_found
    post manual_delivery_run_route_publication_path(@run)
    assert_response :not_found
    assert_nil @run.reload.route_publication
  end

  test "drivers cannot access publication management" do
    sign_in_as users(:driver)
    post delivery_run_route_publication_path(@run)
    assert_response :forbidden
    get delivery_run_route_publication_path(@run)
    assert_response :forbidden
    post manual_delivery_run_route_publication_path(@run)
    assert_response :forbidden
  end

  test "wizard confirmation saves a draft and schedules publication atomically" do
    orders = @run.delivery_orders.to_a
    orders.each { |order| DeliveryRunPlanner.remove(company: @run.company, delivery_run: @run, order_id: order.id) }
    post delivery_runs_path, params: { delivery_run: { name: "Nueva confirmada", scheduled_date: @run.scheduled_date, driver_id: users(:driver).id, status: "assigned" }, order_ids: orders.map(&:id), confirm_and_optimize: "1" }
    created = @run.company.delivery_runs.find_by!(name: "Nueva confirmada")
    assert_redirected_to delivery_run_path(created)
    assert_equal "draft", created.status
    assert_equal "pending", created.route_publication.state
    assert_equal orders.map(&:id).sort, created.delivery_orders.pluck(:id).sort
  end

  test "wizard confirmation without a driver does not leave an incomplete route" do
    assert_no_difference "DeliveryRun.count" do
      post delivery_runs_path, params: { delivery_run: { name: "Sin conductor", scheduled_date: @run.scheduled_date, status: "draft" }, confirm_and_optimize: "1" }
      assert_response :unprocessable_entity
    end
    assert_match "repartidor activo", response.body
  end
end
