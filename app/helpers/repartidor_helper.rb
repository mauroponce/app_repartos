module RepartidorHelper
  def driver_visit_time(visit)
    schedule = visit.delivery_orders.first || visit.delivery_schedule
    schedule ? schedule_time(schedule) : "Sin horario indicado"
  end

  def driver_navigation_url(visit)
    customer = visit.customer
    destination = if visit.current_customer_location?
      "#{customer.latitude},#{customer.longitude}"
    else
      visit.customer_address
    end
    "https://www.google.com/maps/dir/?#{ { api: 1, destination: destination, travelmode: 'driving' }.to_query }"
  end
end
