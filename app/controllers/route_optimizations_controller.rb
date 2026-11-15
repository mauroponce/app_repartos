class RouteOptimizationsController < ManagementController
  def create
    response.headers["Cache-Control"] = "no-store"
    input = params.expect(optimization: [ :date, order_ids: [], settings: [ depot: [], vehicles: [ [ :driver_id, :capacity, :start, :finish ] ] ],
      pins: {}, routes: [ [ :driver_id, job_ids: [] ] ] ])
    result = DeliveryRouteOptimizer.call(company: Current.company, date: input[:date], order_ids: input[:order_ids],
      settings: (input[:settings] || {}).to_h, pins: (input[:pins] || {}).to_h, routes: input[:routes]&.map(&:to_h))
    render json: result
  rescue Osrm::Client::Error, ArgumentError, VroomClient::Error => error
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
