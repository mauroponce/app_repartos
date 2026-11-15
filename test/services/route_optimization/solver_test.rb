require "test_helper"

class RouteOptimizationSolverTest < ActiveSupport::TestCase
  def build(n, **options)
    stops = (0...n).map { |i| { id: 100 + i, index: i, service: 60 } }
    matrix = Array.new(n) { |i| Array.new(n) { |j| i == j ? 0 : ((i - j).abs * 100 + (i < j ? 3 : 11)) } }
    RouteOptimization::Solver.new(stops: stops, durations: matrix, distances: matrix.map { |row| row.map { |v| v * 10 } }, **options)
  end

  [ 0, 1, 2, 5, 10, 25, 50, 100 ].each do |n|
    test "#{n} stops preserve identity completeness and non negative metrics" do
      solver = build(n)
      result = solver.call
      proposal = result[:proposed]
      assert_equal solver.stops.map { |row| row[:id] }.sort, proposal[:visit_ids].sort
      assert_equal n, proposal[:visit_ids].uniq.size
      assert proposal[:feasible]
      %i[distance driving waiting service total preference_penalty].each { |key| assert_operator proposal[key], :>=, 0 }
      assert_operator solver.score(proposal) <=> solver.score(result[:original]), :<=, 0
    end
  end

  test "same inputs produce exactly the same output" do
    assert_equal build(25).call, build(25).call
    solver = build(10)
    assert_equal solver.call, solver.call
  end

  test "optimal original order is retained on equal score" do
    solver = build(5)
    original = solver.stops.map { |row| row[:id] }
    assert_equal original, solver.call[:proposed][:visit_ids]
  end

  test "inefficient order is improved by the heuristic" do
    solver = build(10)
    solver.stops.replace(solver.stops.values_at(0, 9, 1, 8, 2, 7, 3, 6, 4, 5))
    result = solver.call(exact: false)
    assert result[:improved]
    assert_operator result[:proposed][:driving], :<, result[:original][:driving]
  end

  test "asymmetric costs are evaluated in the actual direction" do
    durations = [ [ 0, 1, 80 ], [ 50, 0, 2 ], [ 90, 70, 0 ] ]
    solver = RouteOptimization::Solver.new(stops: [ { id: 3, index: 2 }, { id: 1, index: 0 }, { id: 2, index: 1 } ], durations: durations, distances: durations)
    assert_equal [ 1, 2, 3 ], solver.call[:proposed][:visit_ids]
    assert_equal 3, solver.call[:proposed][:driving]
  end

  test "coincident coordinates and zero distance do not remove distinct visits" do
    solver = RouteOptimization::Solver.new(stops: [ { id: 1, index: 0 }, { id: 2, index: 1 } ], durations: [ [ 0, 0 ], [ 0, 0 ] ], distances: [ [ 0, 0 ], [ 0, 0 ] ])
    assert_equal [ 1, 2 ], solver.call[:proposed][:visit_ids]
  end

  test "open route starts at the first customer with no invented approach leg" do
    value = build(1, departure: 30_000).call[:proposed]
    assert_equal 0, value[:driving]
    assert_equal 30_000, value[:stops].first[:arrival]
  end

  test "depot can differ from every visit and adds both outbound and return arcs" do
    stops = [ { id: 1, index: 1, service: 30 }, { id: 2, index: 2, service: 30 } ]
    matrix = [ [ 0, 10, 90 ], [ 80, 0, 20 ], [ 30, 70, 0 ] ]
    solver = RouteOptimization::Solver.new(stops: stops, durations: matrix, distances: matrix, depot_index: 0, return_to_depot: true)
    result = solver.call[:proposed]
    assert_equal 60, result[:driving]
    assert_equal 120, result[:total]
  end

  test "early arrival waits and service occurs inside the mandatory window" do
    solver = build(1, departure: 100)
    solver.stops.first.merge!(window_start: 500, window_end: 700)
    value = solver.call[:proposed]
    assert_equal 400, value[:waiting]
    assert_equal 500, value[:stops].first[:service_start]
    assert_equal 460, value[:total]
  end

  test "impossible windows never produce a feasible proposal" do
    solver = build(2, departure: 1000)
    solver.stops.each { |row| row.merge!(window_start: 100, window_end: 200) }
    assert_not solver.call[:proposed][:feasible]
    assert_equal 2, solver.call[:proposed][:violations]
  end

  test "mandatory windows dominate travel savings" do
    solver = build(3, departure: 0)
    solver.stops[2].merge!(window_start: 0, window_end: 1)
    result = solver.call[:proposed]
    assert result[:feasible]
    assert_equal 102, result[:visit_ids].first
  end

  test "preferred times are penalized after tolerance but remain soft constraints" do
    solver = build(1, departure: 1000, tolerance: 100)
    solver.stops.first[:preferred] = 800
    result = solver.call[:proposed]
    assert result[:feasible]
    assert_equal 200, result[:preference_penalty]
  end

  test "preferred time inside tolerance adds no penalty" do
    solver = build(1, departure: 1000, tolerance: 100)
    solver.stops.first[:preferred] = 950
    assert_equal 0, solver.call[:proposed][:preference_penalty]
  end

  test "service durations contribute to subsequent arrivals" do
    solver = build(2, departure: 0)
    value = solver.evaluate(solver.stops)
    assert_equal 120, value[:service]
    assert_equal 163, value[:stops].last[:arrival]
  end

  test "fastest driving takes precedence over a shorter distance" do
    stops = [ { id: 1, index: 0 }, { id: 2, index: 1 } ]
    solver = RouteOptimization::Solver.new(stops: stops, durations: [ [ 0, 10 ], [ 30, 0 ] ], distances: [ [ 0, 1000 ], [ 1, 0 ] ])
    assert_equal [ 1, 2 ], solver.call[:proposed][:visit_ids]
  end

  test "inaccessible arcs are explicit and may be avoided if a connected order exists" do
    solver = build(3)
    solver.durations[0][1] = solver.distances[0][1] = nil
    result = solver.call
    assert_not result[:original][:feasible]
    assert result[:proposed][:feasible]
  end

  test "disconnected components cannot be presented as valid" do
    solver = build(3)
    3.times { |i| 3.times { |j| solver.durations[i][j] = solver.distances[i][j] = nil unless i == j } }
    assert_not solver.call[:proposed][:feasible]
  end

  test "exact reference bounds the heuristic on small asymmetric fixtures" do
    4.times do |seed|
      rng = Random.new(seed)
      stops = 6.times.map { |i| { id: i + 1, index: i, service: i * 10 } }
      matrix = Array.new(6) { |i| Array.new(6) { |j| i == j ? 0 : rng.rand(10..300) } }
      exact = RouteOptimization::Solver.new(stops: stops, durations: matrix, distances: matrix).call(exact: true)
      heuristic = RouteOptimization::Solver.new(stops: stops, durations: matrix, distances: matrix).call(exact: false)
      assert_operator exact[:proposed][:objective], :<=, heuristic[:proposed][:objective]
      assert_operator heuristic[:proposed][:objective], :<=, heuristic[:original][:objective]
    end
  end

  test "duplicate visits and invalid matrix dimensions are rejected" do
    assert_raises(ArgumentError) { RouteOptimization::Solver.new(stops: [ { id: 1, index: 0 }, { id: 1, index: 1 } ], durations: [ [ 0, 1 ], [ 1, 0 ] ], distances: [ [ 0, 1 ], [ 1, 0 ] ]) }
    assert_raises(ArgumentError) { RouteOptimization::Solver.new(stops: [], durations: [ [ 0 ] ], distances: []) }
  end

  test "negative matrix values cannot create fictitious improvements" do
    assert_raises(ArgumentError) { RouteOptimization::Solver.new(stops: [ { id: 1, index: 0 } ], durations: [ [ -1 ] ], distances: [ [ 0 ] ]) }
  end

  test "return to depot requires an explicit origin" do
    assert_raises(ArgumentError) { build(2, return_to_depot: true) }
  end
end
