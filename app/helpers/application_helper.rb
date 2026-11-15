module ApplicationHelper
  def historical_money(value, currency = Current.company.currency)
    value.nil? ? "Sin informar" : number_to_currency(value, unit: "#{currency} ", precision: 2)
  end

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

  def delivery_order_status(order)
    { "pending" => "Pendiente", "assigned" => "Asignada a hoja", "completed" => "Completada", "needs_attention" => "Requiere intervención", "rescheduled" => "Reprogramada", "cancelled" => "Cancelada" }.fetch(order.display_status)
  end

  def fulfillment_label(order)
    { "unrecorded" => "Sin confirmar", "unknown" => "Cantidades históricas incompletas", "full" => "Entrega completa", "partial" => "Entrega parcial", "none" => "Mercadería no entregada" }.fetch(order.fulfillment_result)
  end

  def merchandise_summary(order)
    order.delivery_order_items.map { |item| "#{quantity_text(item.quantity)} #{item.unit} · #{item.description}" }.join("; ")
  end

  def operation_status(status)
    { "draft" => "Borrador", "assigned" => "Asignado", "in_progress" => "En curso", "completed" => "Completado", "cancelled" => "Cancelado", "pending" => "Pendiente", "not_attended" => "No atendido", "closed" => "Cerrado", "rescheduled" => "Reprogramado", "rejected" => "Rechazada" }.fetch(status)
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
