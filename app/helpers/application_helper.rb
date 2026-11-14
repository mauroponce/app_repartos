module ApplicationHelper
  def quantity_text(quantity)
    quantity.nil? ? "Sin registrar" : number_with_precision(quantity, precision: 3, strip_insignificant_zeros: true, delimiter: ".", separator: ",")
  end

  def product_options(products)
    products.map { |product| [ product.name + (product.active? ? "" : " (inactivo)"), product.id, { "data-description" => product.name, "data-unit" => product.unit } ] }
  end

  def schedule_time(schedule)
    if schedule.preferred_time
      schedule.preferred_time.strftime("%H:%M")
    elsif schedule.window_start && schedule.window_end
      "#{schedule.window_start.strftime('%H:%M')}–#{schedule.window_end.strftime('%H:%M')}"
    else
      "Sin horario"
    end
  end

  def operation_status(status)
    { "draft" => "Borrador", "assigned" => "Asignado", "in_progress" => "En curso", "completed" => "Completado", "cancelled" => "Cancelado", "pending" => "Pendiente", "not_attended" => "No atendido", "closed" => "Cerrado", "rescheduled" => "Reprogramado" }.fetch(status)
  end

  def customer_location_data(customer, readonly: false)
    {
      controller: "location",
      location_readonly_value: readonly,
      location_latitude_value: customer.latitude,
      location_longitude_value: customer.longitude,
      location_photon_url_value: ENV["PHOTON_URL"].presence || "https://photon.komoot.io/api/",
      location_tiles_url_value: ENV["OSM_TILES_URL"].presence || "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    }
  end

  def icon(name, extra_class = nil)
    tag.svg(class: [ "ic", extra_class ], aria: { hidden: true }) do
      tag.use(href: "#i-#{name}")
    end
  end

  def initials(name)
    name.to_s.split.first(2).map { |word| word.first }.join.upcase
  end

  def customer_status(customer)
    customer.active? ? "Activo" : "Inactivo"
  end

  def role_name(user)
    { "administrator" => "Administración", "supervisor" => "Supervisión", "driver" => "Repartidor" }.fetch(user.role)
  end
end
