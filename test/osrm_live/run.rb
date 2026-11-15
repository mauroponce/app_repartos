# Optional real integration, invoked explicitly by bin/test-osrm.
raise "Live routing checks cannot run in production" if Rails.env.production?
client = Osrm::Client.new
coordinates = [ [ -58.3816, -34.6037 ], [ -58.435, -34.609 ], [ -58.39, -34.606 ], [ -58.44, -34.601 ], [ -58.40, -34.61 ] ]
matrix = client.table(coordinates)
raise "Invalid real matrix" unless matrix[:durations].size == 5 && matrix[:durations].flatten.compact.all? { |value| value >= 0 }
route = client.route(coordinates)
raise "Invalid real road route" unless route["distance"].positive? && route["duration"].positive? && route.dig("geometry", "type") == "LineString"
stops = coordinates.each_index.map { |index| { id: index + 1, index: index, service: 300 } }
result = RouteOptimization::Solver.new(stops: stops, **matrix).call
raise "Missing visits" unless result[:proposed][:visit_ids].sort == stops.map { |row| row[:id] }
raise "Infeasible result" unless result[:proposed][:feasible]
raise "Worse solution" if result[:proposed][:objective] > result[:original][:objective]
puts({ live_osrm: "OK", table_locations: 5, original_metres: result[:original][:distance], proposed_metres: result[:proposed][:distance], original_seconds: result[:original][:driving], proposed_seconds: result[:proposed][:driving], geometry_points: route.dig("geometry", "coordinates").size }.to_json)
