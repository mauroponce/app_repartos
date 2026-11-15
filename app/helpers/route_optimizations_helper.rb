module RouteOptimizationsHelper
  def route_duration(seconds)
    value = seconds.to_f
    sign = value.negative? ? "−" : ""
    minutes = (value.abs / 60).round
    "#{sign}#{minutes / 60} h #{minutes % 60} min"
  end

  def route_savings_percent(saving, original)
    original.to_f.positive? ? number_to_percentage(saving.to_f * 100 / original.to_f, precision: 1) : "Sin base"
  end

  def route_clock(run, seconds)
    day = run.scheduled_date
    local = ActiveSupport::TimeZone[run.company.time_zone].local(day.year, day.month, day.day) + seconds.to_f
    l(local, format: "%d/%m %H:%M")
  end
end
