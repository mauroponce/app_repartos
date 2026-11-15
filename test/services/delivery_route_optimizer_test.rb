require "test_helper"
require_relative "../test_helpers/route_optimization_test_helper"

class DeliveryRouteOptimizerTest < ActiveSupport::TestCase
  include RouteOptimizationTestHelper

  test "builds real street routing input with grouped load service windows and vehicle shifts" do
    first = optimization_order(load_units: 3, service_minutes: 7)
    same = optimization_order(load_units: 2, service_minutes: 4)
    window = optimization_order(time: nil, window_start: "12:00", window_end: "14:00")
    problem = RouteOptimizationProblem.new(**optimization_input([ first, same, window ]))
    payload = problem.payload(pins: { first.id => users(:driver).id })
    assert_equal 2, payload[:jobs].size
    job = payload[:jobs].first
    assert_equal [ -58.337029, -34.8003128 ], job[:location]
    assert_equal [ 5 ], job[:delivery]
    assert_equal 660, job[:service]
    assert_equal [ [ 32400, 32400 ] ], job[:time_windows]
    assert_equal [ users(:driver).id ], job[:skills]
    assert_equal [ [ 43200, 50400 ] ], payload[:jobs].last[:time_windows]
    assert_equal [ 28800, 64800 ], payload[:vehicles].first[:time_window]
    assert_equal payload[:vehicles].first[:start], payload[:vehicles].first[:end]
    assert payload[:options][:g]
    assert_not payload.key?(:matrices)
    assert_not payload.to_json.include?(customers(:one).name)
  end

  test "returns unsaved proposals and creates several routes atomically with idempotent confirmation" do
    first, second = optimization_order, optimization_order(time: "10:00")
    extra = companies(:one).users.create!(name: "Segundo", email_address: "optimizer@example.test", role: :driver, password: "Optimizer-test-2026")
    response = optimization_response({ users(:driver) => [ first ], extra => [ second ] })
    proposal = nil
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      proposal = proposal_for([ first, second ], response: response, drivers: [ users(:driver), extra ])
    end
    assert_equal 2, proposal["routes"].size
    assert proposal["token"].present?
    runs = nil
    assert_difference "DeliveryRun.count", 2 do
      runs = OptimizedDeliveryRunPlanner.call(company: companies(:one), token: proposal["token"], name: "Martes", status: "assigned")
    end
    assert runs.all?(&:assigned?)
    assert_equal [ first.id, second.id ].sort, runs.flat_map { |run| run.delivery_orders.pluck(:id) }.sort
    assert_equal 5000, runs.first.optimization_data["distance"]
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      retry_runs = OptimizedDeliveryRunPlanner.call(company: companies(:one), token: proposal["token"], name: "Martes", status: "assigned")
      assert_equal runs.map(&:id), retry_runs.map(&:id)
    end
  end

  test "grouped deliveries retain one visit and all execution snapshots" do
    first, second = optimization_order, optimization_order
    proposal = proposal_for([ first, second ], response: optimization_response({ users(:driver) => [ first ] }))
    run = OptimizedDeliveryRunPlanner.call(company: companies(:one), token: proposal["token"], name: "Agrupadas", status: "draft").first
    assert_equal 1, run.visits.count
    assert_equal 2, run.visits.first.delivery_items.count
    assert_equal first.reload.visit_id, second.reload.visit_id
  end

  test "unassigned jobs and constraint violations never receive a confirmation token" do
    first, second = optimization_order, optimization_order(time: "10:00")
    proposal = proposal_for([ first, second ], response: optimization_response({ users(:driver) => [ first ] }, unassigned: [ second ]))
    assert_equal [ second.id ], proposal["unassigned"].map { |stop| stop["id"] }
    assert_nil proposal["token"]
    proposal = proposal_for([ first ], response: optimization_response({ users(:driver) => [ first ] }, violations: [ { "cause" => "delay" } ]))
    assert_includes proposal["violations"], "delay"
    assert_nil proposal["token"]
    first.update!(load_units: 101)
    proposal = proposal_for([ first ])
    assert_includes proposal["violations"], "load"
    assert_nil proposal["token"]
  end

  test "manual validation sends exact steps in plan mode and rejects changed results" do
    first, second = optimization_order(time: nil), optimization_order(time: "10:00")
    rows = [ { "driver_id" => users(:driver).id, "job_ids" => [ second.id, first.id ] } ]
    input = optimization_input([ first, second ])
    payload = RouteOptimizationProblem.new(**input).payload(routes: rows)
    assert payload[:options][:c]
    assert_equal [ second.id, first.id ], payload[:vehicles].first[:steps].filter_map { |step| step[:id] }
    client = Object.new
    response = optimization_response({ users(:driver) => [ second, first ] })
    client.define_singleton_method(:call) { |_payload| response }
    proposal = DeliveryRouteOptimizer.call(**input, routes: rows, client: client)
    assert proposal["token"].present?
    assert_raises DeliveryRouteOptimizer::InvalidResponse do
      DeliveryRouteOptimizer.call(**input, routes: [ rows.first.merge("job_ids" => [ first.id, second.id ]) ], client: client)
    end
    assert_raises ArgumentError do
      RouteOptimizationProblem.new(**input).payload(routes: [ rows.first.merge("job_ids" => [ first.id, first.id ]) ])
    end
  end

  test "plan mode ignores unused vehicles without road geometry" do
    order = optimization_order
    extra = companies(:one).users.create!(name: "Sin carga", email_address: "unused@example.test", role: :driver, password: "Optimizer-test-2026")
    response = optimization_response({ users(:driver) => [ order ] })
    response["routes"] << { "vehicle" => extra.id, "steps" => [ { "type" => "start", "arrival" => 28800 }, { "type" => "end", "arrival" => 28800 } ] }
    proposal = proposal_for([ order ], response: response, drivers: [ users(:driver), extra ])
    assert_equal 1, proposal["routes"].size
    assert proposal["token"].present?
  end

  test "a failure saving the second route rolls back all assignments" do
    first, second = optimization_order, optimization_order(time: "10:00")
    extra = companies(:one).users.create!(name: "Segundo", email_address: "atomic@example.test", role: :driver, password: "Optimizer-test-2026")
    response = optimization_response({ users(:driver) => [ first ], extra => [ second ] })
    token = proposal_for([ first, second ], response: response, drivers: [ users(:driver), extra ])["token"]
    original = DeliveryRunPlanner.method(:call)
    count = 0
    DeliveryRunPlanner.define_singleton_method(:call) do |**args|
      count += 1
      raise ActiveRecord::RecordInvalid.new(args[:delivery_run]) if count == 2
      original.call(**args)
    end
    assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) { OptimizedDeliveryRunPlanner.call(company: companies(:one), token: token, name: "Atómica", status: "assigned") }
    end
    assert_nil first.reload.visit_id
    assert_nil second.reload.visit_id
  ensure
    DeliveryRunPlanner.define_singleton_method(:call, original) if original
  end

  test "rejects foreign and inactive drivers foreign orders mixed dates and missing locations" do
    order = optimization_order
    [ users(:other_driver), users(:inactive_driver) ].each do |driver|
      assert_raises ActiveRecord::RecordNotFound do
        RouteOptimizationProblem.new(**optimization_input([ order ], drivers: [ driver ]))
      end
    end
    assert_raises ActiveRecord::RecordNotFound do
      RouteOptimizationProblem.new(**optimization_input([ order ]).merge(company: companies(:two), settings: optimization_settings(drivers: [ users(:other_driver) ])))
    end
    assert_raises(ArgumentError) { RouteOptimizationProblem.new(**optimization_input([ order ]).merge(date: "2026-11-18")) }
    customers(:one).update!(latitude: nil, longitude: nil)
    error = assert_raises(ArgumentError) { RouteOptimizationProblem.new(**optimization_input([ order ])) }
    assert_match(/ubicación/, error.message)
  end

  test "rejects invalid fleet data and split or missing groups" do
    order = optimization_order
    [ 0, -1, "1.5", 1_000_001 ].each do |capacity|
      assert_raises(ArgumentError) { RouteOptimizationProblem.new(**optimization_input([ order ], capacity: capacity)) }
    end
    input = optimization_input([ order ])
    input[:settings]["depot"] = [ "", "" ]
    assert_raises(ArgumentError) { RouteOptimizationProblem.new(**input) }
    input[:settings]["depot"] = [ 181, 45 ]
    assert_raises(ArgumentError) { RouteOptimizationProblem.new(**input) }
    problem = RouteOptimizationProblem.new(**optimization_input([ order ]))
    assert_raises(ArgumentError) { problem.payload(pins: { order.id => users(:other_driver).id }) }
    assert_raises(ArgumentError) { problem.normalize_routes([]) }
  end

  test "rejects fabricated incomplete repeated and geometry-free provider responses" do
    first, second = optimization_order, optimization_order(time: "10:00")
    responses = [
      optimization_response({ users(:driver) => [ first ] }),
      optimization_response({ users(:driver) => [ first, first ] }),
      optimization_response({ users(:other_driver) => [ first, second ] }),
      optimization_response({ users(:driver) => [ first, second ] }).tap { |r| r["routes"].first.delete("geometry") }
    ]
    responses.each do |response|
      assert_raises(DeliveryRouteOptimizer::InvalidResponse) { proposal_for([ first, second ], response: response) }
    end
  end

  test "confirmation rejects stale order item coordinates and driver snapshots and expired or tampered tokens" do
    order = optimization_order
    changes = [ -> { order.update!(service_minutes: 25) }, -> { order.delivery_order_items.first.update!(quantity: 9) },
      -> { customers(:one).update!(latitude: -34.81) }, -> { users(:driver).update!(name: "Nuevo nombre") } ]
    changes.each do |change|
      proposal = proposal_for([ order.reload ])
      change.call
      assert_no_difference [ "DeliveryRun.count", "Visit.count", "DeliveryItem.count" ] do
        assert_raises(ArgumentError) { OptimizedDeliveryRunPlanner.call(company: companies(:one), token: proposal["token"], name: "Martes", status: "draft") }
      end
    end
    token = proposal_for([ order.reload ])["token"]
    [ token + "tampered", "" ].each do |invalid|
      assert_raises(ArgumentError) { OptimizedDeliveryRunPlanner.call(company: companies(:one), token: invalid, name: "Martes", status: "draft") }
    end
    travel 31.minutes do
      assert_raises(ArgumentError) { OptimizedDeliveryRunPlanner.call(company: companies(:one), token: token, name: "Martes", status: "draft") }
    end
    assert_raises(ArgumentError) { OptimizedDeliveryRunPlanner.call(company: companies(:two), token: token, name: "Martes", status: "draft") }
  end

  test "confirmation cannot steal an already planned delivery" do
    order = optimization_order
    token = proposal_for([ order ])["token"]
    manual = companies(:one).delivery_runs.new(name: "Manual", scheduled_date: order.scheduled_date)
    DeliveryRunPlanner.call(company: companies(:one), delivery_run: manual, order_ids: [ order.id ])
    assert_no_difference [ "DeliveryRun.count", "Visit.count" ] do
      assert_raises(ArgumentError) { OptimizedDeliveryRunPlanner.call(company: companies(:one), token: token, name: "Optimizada", status: "draft") }
    end
    assert_equal manual.id, order.reload.visit.delivery_run_id
  end
end
