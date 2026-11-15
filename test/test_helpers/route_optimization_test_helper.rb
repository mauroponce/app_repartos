module RouteOptimizationTestHelper
  def optimization_order(time: "09:00", **attributes)
    companies(:one).delivery_orders.create!({ customer: customers(:one), scheduled_date: "2026-11-17", preferred_time: time,
      delivery_order_items_attributes: [ { description: "Cajones", quantity: 2, unit: "box" } ] }.merge(attributes))
  end

  def optimization_settings(drivers: [ users(:driver) ], capacity: 100)
    { "depot" => [ -58.34, -34.80 ], "vehicles" => drivers.map { |driver| { "driver_id" => driver.id, "capacity" => capacity, "start" => "08:00", "finish" => "18:00" } } }
  end

  def optimization_input(orders, **options)
    { company: companies(:one), date: "2026-11-17", order_ids: orders.map(&:id), settings: optimization_settings(**options) }
  end

  def optimization_response(assignments, unassigned: [], violations: [])
    { "code" => 0, "summary" => { "violations" => violations }, "unassigned" => unassigned.map { |order| { "id" => order.id } },
      "routes" => assignments.map do |driver, orders|
        { "vehicle" => driver.id, "geometry" => "_p~iF~ps|U_ulLnnqC_mqNvxq`@", "distance" => 5000, "duration" => 1200, "violations" => violations,
          "steps" => [ { "type" => "start", "arrival" => 28800 }, *orders.map do |order|
            { "type" => "job", "id" => order.id, "arrival" => order.preferred_time ? order.preferred_time.seconds_since_midnight.to_i : 32400, "waiting_time" => 0, "violations" => [] }
          end, { "type" => "end", "arrival" => 61200 } ] }
      end }
  end

  def proposal_for(orders, response: nil, **options)
    response ||= optimization_response({ users(:driver) => orders })
    client = Object.new
    client.define_singleton_method(:call) { |_payload| response }
    DeliveryRouteOptimizer.call(**optimization_input(orders, **options), client: client)
  end

  def with_optimization_response(response = nil)
    original = VroomClient.method(:new)
    client = Object.new
    client.define_singleton_method(:call) do |_payload|
      raise VroomClient::Error, "No disponible" unless response
      response
    end
    VroomClient.define_singleton_method(:new) { client }
    yield
  ensure
    VroomClient.define_singleton_method(:new, original)
  end
end
