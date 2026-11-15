require "test_helper"
require_relative "../../test_helpers/single_route_test_helper"

class RouteOptimizationPublicationTest < ActiveSupport::TestCase
  include SingleRouteTestHelper

  setup do
    @run = single_route(status: :draft)
    @manager = users(:one)
    @company = @run.company
    @old_version = ENV["OSRM_MAP_VERSION"]
    ENV["OSRM_MAP_VERSION"] = "publication-test-v1"
    @client = single_client
    @calls = Hash.new(0)
    calls = @calls
    %i[table route].each do |method|
      original = @client.method(method)
      @client.define_singleton_method(method) { |points| calls[method] += 1; original.call(points) }
    end
    @client.define_singleton_method(:cache_identity) { RouteOptimization::Dataset.identity }
  end

  teardown { ENV["OSRM_MAP_VERSION"] = @old_version }

  def prepare
    PrepareRoutePublicationJob.perform_now(@company.id, @run.id)
    @publication.reload.proposal
  end

  def confirm
    @publication = RoutePublication.request!(user: @manager, run: @run.reload)
    prepare
  end

  def finish(proposal = @publication.reload.proposal)
    with_single_client(@client) { OptimizeDeliveryRunJob.perform_now(@company.id, proposal.id) }
  end

  test "confirmation responds with pending work and only publishes the final order after the job" do
    ids = @run.visits.pluck(:id)
    proposal = confirm
    assert_equal "pending", @publication.reload.state
    assert_equal "draft", @run.reload.status
    assert_equal ids, @run.visits.pluck(:id)
    assert_empty @calls
    finish(proposal)
    assert_equal "ready", @publication.reload.state
    assert_equal "assigned", @run.reload.status
    assert_equal "applied", proposal.reload.status
    assert_equal proposal.result.dig("proposed", "visit_ids"), @run.visits.pluck(:id)
    assert_equal @manager.id, proposal.applied_by_id
  end

  test "duplicates before and after completion do not create another proposal or perform calculation" do
    confirm
    2.times { RoutePublication.request!(user: @manager, run: @run.reload); prepare }
    assert_equal 1, @run.route_optimization_proposals.count
    finish
    counts = @calls.dup
    2.times { RoutePublication.request!(user: @manager, run: @run.reload); prepare; finish }
    assert_equal 1, @run.route_optimization_proposals.count
    assert_equal counts, @calls
    assert_equal 1, RoutePublication.where(delivery_run: @run).count
  end

  test "orders quantities prices and history survive automatic confirmation" do
    orders = @run.delivery_orders.map(&:attributes).sort_by { |row| row["id"] }
    items = @company.delivery_items.order(:id).map(&:attributes)
    confirm
    finish
    assert_equal orders, @run.delivery_orders.map(&:attributes).sort_by { |row| row["id"] }
    assert_equal items, @company.delivery_items.order(:id).map(&:attributes)
  end

  test "renaming and commercial quantity changes reuse a ready route" do
    confirm
    finish
    counts = @calls.dup
    @run.update!(name: "Nuevo nombre")
    order = @run.delivery_orders.first
    DeliveryOrderEditor.call(order: order, attributes: { delivery_order_items_attributes: [ { id: order.delivery_order_items.first.id, quantity: 8 } ] })
    RoutePublication.request!(user: @manager, run: @run.reload)
    assert_equal "ready", @publication.reload.state
    assert_equal counts, @calls
    assert_equal 1, @run.route_optimization_proposals.count
  end

  test "non routing edits during the job do not discard a usable result" do
    confirm
    original = @client.method(:table)
    run = @run
    @client.define_singleton_method(:table) { |points| run.update!(name: "Editada durante el cálculo"); original.call(points) }
    finish
    assert_equal "ready", @publication.reload.state
    assert_equal "assigned", @run.reload.status
  end

  test "changing coordinates blocks the published route and recalculates its road matrix" do
    confirm
    finish
    proof = DriverWorkSnapshot.issue(user: users(:driver), visit: @run.visits.first)
    @run.visits.first.customer.update!(latitude: -34.79)
    assert_equal "pending", @publication.reload.state
    assert_nil @publication.proposal_id
    assert_not_includes @company.delivery_runs.published_to_driver, @run
    assert_not DriverWorkSnapshot.matches?(@run.visits.first.reload, DriverWorkSnapshot.read(proof))
    prepare
    finish
    assert_equal 2, @calls[:table]
    assert_equal "ready", @publication.reload.state
  end

  test "changing service duration reruns optimization while reusing road distances" do
    confirm
    finish
    @run.delivery_orders.first.update!(service_minutes: 9)
    assert_equal "pending", @publication.reload.state
    prepare
    finish
    assert_equal 1, @calls[:table]
    assert_equal 19 * 60, @publication.reload.proposal.result.dig("proposed", "service")
  end

  test "company time and preference settings invalidate the solution but keep its road matrix" do
    confirm
    finish
    @company.update!(routing_departure: "09:00", routing_preferred_tolerance: 20)
    assert_equal "pending", @publication.reload.state
    prepare
    finish
    assert_equal 1, @calls[:table]
    assert_equal 32_400, @publication.reload.proposal.result.dig("proposed", "departure")
  end

  test "adding or removing grouped orders recalculates service without querying unchanged road points" do
    confirm
    finish
    original = @run.delivery_orders.first
    extra = @company.delivery_orders.create!(customer: original.customer, scheduled_date: @run.scheduled_date, service_minutes: 7,
      delivery_order_items_attributes: [ { description: "Extra", unit: "box", quantity: 1 } ])
    DeliveryRunPlanner.call(company: @company, delivery_run: @run.reload, order_ids: [ extra.id ])
    prepare
    finish
    assert_equal 1, @calls[:table]
    assert_equal 22 * 60, @publication.reload.proposal.result.dig("proposed", "service")
    DeliveryRunPlanner.remove(company: @company, delivery_run: @run.reload, order_id: extra.id)
    prepare
    finish
    assert_equal 1, @calls[:table]
    assert_equal "ready", @publication.reload.state
  end

  test "a stale job cannot publish after another edit or after selecting manual publication" do
    stale = confirm
    @run.delivery_orders.first.update!(service_minutes: 12)
    finish(stale)
    assert_equal "pending", @publication.reload.state
    assert_equal "draft", @run.reload.status
    newer = prepare
    assert_not_equal stale.id, newer.id
    RoutePublication.use_manual!(user: @manager, run: @run)
    finish(newer)
    assert_equal "manual", @publication.reload.state
    assert_equal "assigned", @run.reload.status
    assert_not_equal "applied", newer.reload.status
  end

  test "a deliberate manual reorder cancels automatic publication and preserves administrator intent" do
    confirm
    finish
    ids = @run.visits.pluck(:id).reverse
    DeliveryRunReorderer.call(company: @company, delivery_run: @run, visit_ids: ids)
    assert_equal "manual", @publication.reload.state
    assert_equal ids, @run.visits.pluck(:id)
    assert_includes @company.delivery_runs.published_to_driver, @run
  end

  test "OSRM failure preserves the plan and allows an explicit manual publication" do
    confirm
    @client.define_singleton_method(:table) { |_| raise Osrm::Client::Unavailable, "Sin conexión a OSRM" }
    ids = @run.visits.pluck(:id)
    finish
    assert_equal "failed", @publication.reload.state
    assert_match(/OSRM/, @publication.error_message)
    assert_equal ids, @run.visits.pluck(:id)
    assert_equal "draft", @run.reload.status
    RoutePublication.use_manual!(user: @manager, run: @run)
    assert_equal "assigned", @run.reload.status
  end

  test "infeasible windows never publish the route" do
    @run.delivery_orders.each do |order|
      DeliveryRunPlanner.remove(company: @company, delivery_run: @run, order_id: order.id)
      order.reload.update!(window_start: "08:00", window_end: "08:01")
      DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ order.id ])
    end
    confirm
    finish
    assert_equal "failed", @publication.reload.state
    assert_equal "draft", @run.reload.status
  end

  test "driver receipts and checkpoints are blocked until publication" do
    @run.update!(status: :assigned)
    visit = @run.visits.first
    proof = DriverWorkSnapshot.read(DriverWorkSnapshot.issue(user: users(:driver), visit: visit))
    confirm
    assert_raises(DriverVisitRecorder::Conflict) do
      DriverVisitRecorder.call(user: users(:driver), visit_id: visit.id, attributes: { status: "completed", items: [] })
    end
    assert_raises(DriverVisitRecorder::Conflict) do
      DriverVisitCheckpointRecorder.call(user: users(:driver), visit_id: visit.id, checkpoint: "arrived_at", occurred_at: Time.current.iso8601, offline_proof: proof)
    end
    assert_raises(ActiveRecord::RecordInvalid) { visit.update!(arrived_at: Time.current) }
    assert_nil visit.reload.arrived_at
  end

  test "started runs never enter automatic optimization or change order on customer edits" do
    confirm
    finish
    visit = @run.reload.visits.first
    proof = DriverWorkSnapshot.read(DriverWorkSnapshot.issue(user: users(:driver), visit: visit))
    DriverVisitCheckpointRecorder.call(user: users(:driver), visit_id: visit.id, checkpoint: "arrived_at", occurred_at: Time.current.iso8601, offline_proof: proof)
    ids = @run.visits.pluck(:id)
    visit.customer.update!(latitude: -34.78)
    assert_equal "ready", @publication.reload.state
    assert_equal ids, @run.visits.pluck(:id)
    assert_raises(ArgumentError) { RoutePublication.request!(user: @manager, run: @run.reload) }
  end

  test "revoked administrative permission prevents publication" do
    confirm
    @manager.update!(status: :inactive)
    finish
    assert_equal "failed", @publication.reload.state
    assert_equal "draft", @run.reload.status
  end

  test "tenant scoped jobs do not publish another company's route" do
    confirm
    PrepareRoutePublicationJob.perform_now(companies(:two).id, @run.id)
    with_single_client(@client) { OptimizeDeliveryRunJob.perform_now(companies(:two).id, @publication.proposal_id) }
    assert_equal "pending", @publication.reload.state
    assert_empty @calls
    assert_raises(ArgumentError) { RoutePublication.request!(user: users(:two), run: @run) }
    assert_raises(ArgumentError) { RoutePublication.use_manual!(user: users(:driver), run: @run) }
  end

  test "a new map version invalidates both persistent cache layers" do
    confirm
    finish
    ENV["OSRM_MAP_VERSION"] = "publication-test-v2"
    @publication = RoutePublication.request!(user: @manager, run: @run.reload)
    prepare
    finish
    assert_equal 2, @calls[:table]
    assert_equal "ready", @publication.reload.state
  end

  test "maintenance detects a changed dataset without recalculating a started journey" do
    confirm
    finish
    ENV["OSRM_MAP_VERSION"] = "publication-test-updated"
    RouteProposalMaintenanceJob.perform_now(@company.id)
    assert_equal "pending", @publication.reload.state
    prepare
    finish
    assert_equal "ready", @publication.reload.state
    assert_equal 2, @calls[:table]
  end

  test "a routing edit during calculation supersedes the old job and publishes only the latest input" do
    old = confirm
    original = @client.method(:table)
    order = @run.delivery_orders.first
    @client.define_singleton_method(:table) { |points| order.update!(service_minutes: 9); original.call(points) }
    finish(old)
    assert_equal "discarded", old.reload.status
    assert_equal "pending", @publication.reload.state
    assert_equal "draft", @run.reload.status
    prepare
    finish
    assert_equal "ready", @publication.reload.state
    assert_equal 19 * 60, @publication.proposal.result.dig("proposed", "service")
  end

  test "an expired automatic proposal leaves an explicit recoverable failure" do
    proposal = confirm
    proposal.update!(expires_at: 1.second.ago)
    finish(proposal)
    assert_equal "expired", proposal.reload.status
    assert_equal "failed", @publication.reload.state
    assert_match(/venció/, @publication.error_message)
  end

  test "changing the map during computation rolls back all newly cached results" do
    proposal = confirm
    original = @client.method(:table)
    @client.define_singleton_method(:table) do |points|
      ENV["OSRM_MAP_VERSION"] = "changed-while-computing"
      original.call(points)
    end
    finish(proposal)
    assert_equal "failed", @publication.reload.state
    assert_equal 0, @company.routing_cache_entries.count
    assert_equal "draft", @run.reload.status
  end

  test "cache keys reuse unchanged inputs and ignore visit positions and customer metadata" do
    before = RouteOptimization::Problem.new(@run).calculation_key
    @run.visits.first.customer.update!(name: "Nombre actualizado", phone: "999")
    @run.update!(name: "Otro nombre")
    DeliveryRunReorderer.call(company: @company, delivery_run: @run, visit_ids: @run.visits.pluck(:id).reverse)
    assert_equal before, RouteOptimization::Problem.new(@run.reload).calculation_key
  end
end
