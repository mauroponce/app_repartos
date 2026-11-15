# Optional real OSRM integration. Does not apply an optimization or change stops.
abort "Usá ONBOARDING_OSRM_CHECK=1 en desarrollo." unless Rails.env.development? && ENV["ONBOARDING_OSRM_CHECK"] == "1"
company = Company.find_by!(slug: DemoOnboardingSeeds::SLUG)
run = company.delivery_runs.find_by!(generation_key: "onboarding:v1:0")
problem = RouteOptimization::Problem.new(run, settings: { origin: "open", departure: "08:00", return_to_depot: false })
result = problem.calculate
raise "OSRM did not provide road geometry" unless result.dig(:proposed, :geometry).present?
puts JSON.pretty_generate(osrm: "OK", synthetic_demo_points: true, applied: false, run_id: run.id,
  algorithm: result[:algorithm], feasible: result.dig(:proposed, :feasible),
  distance_meters: result.dig(:proposed, :distance), driving_seconds: result.dig(:proposed, :driving), dataset: result[:dataset_identity])
