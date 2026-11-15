require "test_helper"
require_relative "../test_helpers/single_route_test_helper"

class SingleRouteOptimizationsControllerTest < ActionDispatch::IntegrationTest
  include SingleRouteTestHelper
  setup { @run = single_route; sign_in_as users(:one) }

  test "administrator sees functional configuration preview loading result and confirmation" do
    get delivery_run_path(@run)
    assert_select "a", text: "Optimizar ruta"
    get new_delivery_run_optimization_proposal_path(@run)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "meta[name='turbo-cache-control'][content='no-cache']"
    assert_match "Recorrido abierto", response.body
    ids = @run.visits.pluck(:id)
    post delivery_run_optimization_proposals_path(@run), params: { optimization: { origin: "open", departure: "08:00", return_to_depot: "0" }, provider_url: "http://invalid-provider.example" }
    proposal = @run.route_optimization_proposals.sole
    assert_redirected_to delivery_run_optimization_proposal_path(@run, proposal)
    assert_equal ids, @run.visits.pluck(:id)
    get delivery_run_optimization_proposal_path(@run, proposal)
    assert_match "Cálculo en cola", response.body
    with_single_client { OptimizeDeliveryRunJob.perform_now(@run.company_id, proposal.id) }
    get delivery_run_optimization_proposal_path(@run, proposal)
    assert_response :success
    assert_select "h2", text: "Ruta propuesta"
    assert_select "button", text: "Confirmar orden propuesto"
    assert_match "Atención", response.body
    post apply_delivery_run_optimization_proposal_path(@run, proposal)
    assert_redirected_to delivery_run_path(@run)
    assert_equal "applied", proposal.reload.status
    assert_equal proposal.result.dig("proposed", "visit_ids"), @run.visits.pluck(:id)
  end

  test "discard is a persisted decision without a route mutation" do
    proposal = ready_single_proposal(@run)
    original = @run.visits.pluck(:id)
    delete delivery_run_optimization_proposal_path(@run, proposal)
    assert_redirected_to delivery_run_path(@run)
    assert_equal "discarded", proposal.reload.status
    assert_equal original, @run.visits.pluck(:id)
  end

  test "drivers cannot view request apply or configure optimizations" do
    proposal = ready_single_proposal(@run)
    sign_in_as users(:driver)
    get new_delivery_run_optimization_proposal_path(@run)
    assert_response :forbidden
    post delivery_run_optimization_proposals_path(@run)
    assert_response :forbidden
    get delivery_run_optimization_proposal_path(@run, proposal)
    assert_response :forbidden
    post apply_delivery_run_optimization_proposal_path(@run, proposal)
    assert_response :forbidden
    get edit_routing_settings_path
    assert_response :forbidden
  end

  test "other company cannot access any proposal or route data" do
    proposal = ready_single_proposal(@run)
    sign_in_as users(:two)
    [ new_delivery_run_optimization_proposal_path(@run), delivery_run_optimization_proposal_path(@run, proposal) ].each do |path|
      get path
      assert_response :not_found
    end
    post apply_delivery_run_optimization_proposal_path(@run, proposal)
    assert_response :not_found
    delete delivery_run_optimization_proposal_path(@run, proposal)
    assert_response :not_found
  end

  test "supervisor can manage proposals" do
    supervisor = @run.company.users.create!(name: "Supervisor rutas", role: :supervisor, email_address: "supervisor-route@example.test", password: "Testing-routes-2026")
    sign_in_as supervisor
    post delivery_run_optimization_proposals_path(@run), params: { optimization: { origin: "open" } }
    assert_response :see_other
    assert_equal supervisor, @run.route_optimization_proposals.sole.requested_by
  end

  test "terminal route has disabled button and request is rejected" do
    @run.update_columns(status: "completed")
    get delivery_run_path(@run)
    assert_select "button[disabled]", text: "Optimizar ruta"
    assert_no_difference "RouteOptimizationProposal.count" do
      post delivery_run_optimization_proposals_path(@run), params: { optimization: { origin: "open" } }
      assert_redirected_to delivery_run_path(@run)
    end
  end

  test "settings update only the current company and validate the coordinate pair" do
    get edit_routing_settings_path
    assert_response :success
    patch routing_settings_path, params: { company: { depot_latitude: "-34.8", depot_longitude: "-58.39", routing_departure: "07:15", routing_return_to_depot: "1", routing_preferred_tolerance: 20, routing_service_minutes: 10 }, company_id: companies(:two).id }
    assert_redirected_to edit_routing_settings_path
    assert_equal "07:15", @run.company.reload.routing_departure
    assert_nil companies(:two).reload.depot_latitude
    patch routing_settings_path, params: { company: { depot_latitude: "", depot_longitude: "-58.39" } }
    assert_response :unprocessable_entity
  end

  test "expired or stale proposals have no side effects" do
    proposal = ready_single_proposal(@run)
    @run.visits.first.customer.update!(latitude: -34.79)
    post apply_delivery_run_optimization_proposal_path(@run, proposal)
    assert_redirected_to delivery_run_path(@run)
    assert_equal "ready", proposal.reload.status
    travel_to 31.minutes.from_now do
      get delivery_run_optimization_proposal_path(@run, proposal, format: :json)
      assert_equal "expired", response.parsed_body["status"]
    end
  end
end
