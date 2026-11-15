require "test_helper"
require_relative "../../test_helpers/single_route_test_helper"

class RouteOptimizationProposalsTest < ActiveSupport::TestCase
  include SingleRouteTestHelper
  include ActiveJob::TestHelper

  setup { @run = single_route; @manager = users(:one); @company = companies(:one) }

  test "preview request persists only a proposal and reuses concurrent retries" do
    before = [ @run.reload.attributes, @run.visits.map(&:attributes), @company.delivery_orders.order(:id).map(&:attributes) ]
    assert_enqueued_with(job: OptimizeDeliveryRunJob) do
      first = RouteOptimizationProposal.request!(user: @manager, run: @run)
      assert_equal first.id, RouteOptimizationProposal.request!(user: @manager, run: @run.reload).id
    end
    assert_equal 1, @run.route_optimization_proposals.count
    assert_equal before, [ @run.reload.attributes, @run.visits.map(&:attributes), @company.delivery_orders.order(:id).map(&:attributes) ]
  end

  test "apply changes only visit position timestamp and records the accepting manager" do
    proposal = ready_single_proposal(@run)
    run_before = @run.reload.attributes
    orders_before = @run.delivery_orders.map(&:attributes).sort_by { |row| row["id"] }
    items_before = @run.visits.flat_map { |visit| visit.delivery_items.map(&:attributes) }.sort_by { |row| row["id"] }
    visits_before = @run.visits.index_by(&:id).transform_values { |visit| visit.attributes.except("position", "updated_at") }
    proposal.apply!(user: @manager)
    assert_equal run_before, @run.reload.attributes
    assert_equal orders_before, @run.delivery_orders.map(&:attributes).sort_by { |row| row["id"] }
    assert_equal items_before, @run.visits.reload.flat_map { |visit| visit.delivery_items.map(&:attributes) }.sort_by { |row| row["id"] }
    assert_equal visits_before, @run.visits.index_by(&:id).transform_values { |visit| visit.attributes.except("position", "updated_at") }
    assert_equal proposal.result.dig("proposed", "visit_ids"), @run.visits.pluck(:id)
    assert_equal @manager, proposal.reload.applied_by
    assert_no_difference("DeliveryStatusEvent.count") { proposal.apply!(user: @manager) }
    DeliveryRunReorderer.call(company: @company, delivery_run: @run, visit_ids: @run.visits.pluck(:id).reverse)
  end

  test "expired proposal cannot change the run" do
    proposal = ready_single_proposal(@run)
    travel_to 31.minutes.from_now do
      assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
      assert_equal "ready", proposal.reload.status
    end
  end

  test "a manually reordered route invalidates the proposal" do
    proposal = ready_single_proposal(@run)
    ids = @run.visits.pluck(:id).reverse
    DeliveryRunReorderer.call(company: @company, delivery_run: @run, visit_ids: ids)
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
    assert_equal ids, @run.visits.pluck(:id)
  end

  test "adding a stop invalidates a proposal" do
    proposal = ready_single_proposal(@run)
    @run.visits.create!(company: @company, customer: @run.visits.first.customer, position: 4)
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
  end

  test "removing an order and its stop invalidates a proposal" do
    proposal = ready_single_proposal(@run)
    DeliveryRunPlanner.remove(company: @company, delivery_run: @run, order_id: @run.delivery_orders.first.id)
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
  end

  test "changed customer coordinates invalidate proposals" do
    proposal = ready_single_proposal(@run)
    @run.visits.first.customer.update!(latitude: -34.805)
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
  end

  test "changed quantity invalidates proposals without losing order relations" do
    proposal = ready_single_proposal(@run)
    order = @run.delivery_orders.first
    DeliveryOrderEditor.call(order: order, attributes: { delivery_order_items_attributes: [ { id: order.delivery_order_items.first.id, quantity: 8 } ] })
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
    assert_equal 2, order.reload.delivery_order_items.count
  end

  test "a driver checkpoint prevents optimization even while visit status is pending" do
    proposal = ready_single_proposal(@run)
    @run.visits.first.update!(arrived_at: Time.current)
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
  end

  %w[in_progress completed cancelled].each do |status|
    test "#{status} run does not admit preview or application" do
      proposal = ready_single_proposal(@run)
      @run.update_columns(status: status)
      assert_raises(ArgumentError) { RouteOptimization::Problem.new(@run.reload) }
      assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
    end
  end

  test "missing coordinates and changed snapshot address are explicit errors" do
    customer = @run.visits.first.customer
    customer.update!(latitude: nil, longitude: nil)
    assert_match(/ubicación/, assert_raises(ArgumentError) { RouteOptimization::Problem.new(@run.reload) }.message)
    customer.update!(latitude: -34.8, longitude: -58.39, address: "Otro domicilio", location_confirmed: true)
    assert_match(/dirección/, assert_raises(ArgumentError) { RouteOptimization::Problem.new(@run.reload) }.message)
  end

  test "grouped orders stay in one stop and their service minutes are added" do
    order = @run.delivery_orders.first
    extra = @company.delivery_orders.create!(customer: order.customer, scheduled_date: @run.scheduled_date, service_minutes: 7,
      delivery_order_items_attributes: [ { description: "Segundo pedido", quantity: 2, unit: "pack" } ])
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ extra.id ])
    problem = RouteOptimization::Problem.new(@run.reload)
    assert_equal 3, problem.stops.size
    assert_equal 720, problem.stops.find { |stop| stop[:id] == order.visit_id }[:service]
    ready_single_proposal(@run).apply!(user: @manager)
    assert_equal order.visit_id, extra.reload.visit_id
  end

  test "depot and local departure are explicit and fingerprinted" do
    @company.update!(depot_latitude: -34.81, depot_longitude: -58.40, time_zone: "Pacific/Auckland", routing_departure: "07:30")
    problem = RouteOptimization::Problem.new(@run.reload, settings: { origin: "depot", return_to_depot: true })
    assert_equal [ -58.4, -34.81 ], problem.coordinates.first
    assert_equal "07:30", problem.settings["departure"]
    value = problem.calculate(client: single_client)
    assert_equal 27_000, value[:proposed][:departure]
    assert value[:return_to_depot]
  end

  test "drivers and other companies cannot request or apply proposals" do
    proposal = ready_single_proposal(@run)
    [ users(:driver), users(:two) ].each do |user|
      assert_raises(ArgumentError) { RouteOptimizationProposal.request!(user: user, run: @run) }
      assert_raises(ArgumentError) { proposal.apply!(user: user) }
    end
  end

  test "fingerprints are timezone independent between an administrative request and its background job" do
    @company.update!(time_zone: "Pacific/Auckland")
    proposal = Time.use_zone("Pacific/Auckland") { RouteOptimizationProposal.request!(user: @manager, run: @run.reload) }
    Time.use_zone("UTC") do
      with_single_client { OptimizeDeliveryRunJob.perform_now(@company.id, proposal.id) }
      assert_equal "ready", proposal.reload.status
      proposal.apply!(user: @manager)
    end
    assert_equal "applied", proposal.reload.status
  end

  test "travel and waiting use actual elapsed time on daylight saving transition days" do
    @company.update!(time_zone: "America/New_York")
    travel_to Time.utc(2026, 3, 8, 6) do
      run = single_route(size: 2)
      order = run.delivery_orders.last
      DeliveryRunPlanner.remove(company: @company, delivery_run: run, order_id: order.id)
      order.reload.update!(window_start: "03:20", window_end: "03:30")
      DeliveryRunPlanner.call(company: @company, delivery_run: run, order_ids: [ order.id ])
      problem = RouteOptimization::Problem.new(run.reload, settings: { departure: "01:50" })
      result = problem.calculate(client: single_client)
      assert result[:proposed][:feasible]
      assert_equal 35 * 60, result[:proposed][:total]
      assert_equal 15 * 60, result[:proposed][:waiting]
      assert_equal "08/03 03:20", ApplicationController.helpers.route_clock(run, result[:proposed][:stops].last[:service_start])
      assert_raises(ArgumentError) { RouteOptimization::Problem.new(run.reload, settings: { departure: "02:30" }) }
      daytime = RouteOptimization::Problem.new(run.reload, settings: { departure: "08:00" }).calculate(client: single_client)
      assert_equal "08/03 08:00", ApplicationController.helpers.route_clock(run, daytime[:original][:departure])
    end
    travel_to Time.utc(2026, 11, 1, 5) do
      run = single_route(size: 1)
      assert_raises(ArgumentError) { RouteOptimization::Problem.new(run, settings: { departure: "01:30" }) }
    end
  end

  test "database rejects cross company proposal references" do
    proposal = ready_single_proposal(@run)
    assert_raises(ActiveRecord::InvalidForeignKey) { RouteOptimizationProposal.transaction(requires_new: true) { proposal.update_columns(requested_by_id: users(:two).id) } }
  end

  test "job failure is recoverable and never changes the plan" do
    proposal = RouteOptimizationProposal.request!(user: @manager, run: @run)
    client = Object.new
    client.define_singleton_method(:table) { |_| raise Osrm::Client::Unavailable, "OSRM no responde" }
    ids = @run.visits.pluck(:id)
    with_single_client(client) { OptimizeDeliveryRunJob.perform_now(@company.id, proposal.id) }
    assert_equal "failed", proposal.reload.status
    assert_equal ids, @run.visits.pluck(:id)
    assert_match(/OSRM/, proposal.error_message)
    assert_not_equal proposal.id, RouteOptimizationProposal.request!(user: @manager, run: @run).id
  end

  test "job is idempotent and requires an explicit matching company" do
    proposal = RouteOptimizationProposal.request!(user: @manager, run: @run)
    with_single_client { OptimizeDeliveryRunJob.perform_now(companies(:two).id, proposal.id) }
    assert_equal "queued", proposal.reload.status
    with_single_client { 2.times { OptimizeDeliveryRunJob.perform_now(@company.id, proposal.id) } }
    assert_equal "ready", proposal.reload.status
  end

  test "stale input during computation is rejected" do
    proposal = RouteOptimizationProposal.request!(user: @manager, run: @run)
    client = single_client
    original = client.method(:table)
    run = @run
    client.define_singleton_method(:table) do |points|
      run.update!(name: "Cambio concurrente")
      original.call(points)
    end
    with_single_client(client) { OptimizeDeliveryRunJob.perform_now(@company.id, proposal.id) }
    assert_equal "failed", proposal.reload.status
  end

  test "discarded and infeasible proposals cannot be applied" do
    proposal = ready_single_proposal(@run)
    proposal.update!(status: "discarded")
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
    proposal.update!(status: "ready", result: proposal.result.deep_merge("proposed" => { "feasible" => false }))
    assert_raises(ArgumentError) { proposal.apply!(user: @manager) }
  end

  test "an error midway through reordering rolls back every position and the application marker" do
    proposal = ready_single_proposal(@run)
    before = @run.visits.pluck(:id, :position)
    failing_id = proposal.result.fetch("proposed").fetch("visit_ids").last
    callback = -> { raise ActiveRecord::RecordInvalid.new(self) if id == failing_id && will_save_change_to_position? }
    Visit.set_callback(:update, :before, callback)
    assert_raises(ActiveRecord::RecordInvalid) { proposal.apply!(user: @manager) }
    assert_equal before, @run.visits.reload.pluck(:id, :position)
    assert_equal "ready", proposal.reload.status
  ensure
    Visit.skip_callback(:update, :before, callback) if callback
  end
end
