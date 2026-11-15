require "net/http"

class OperationsEta
  class Unavailable < StandardError; end

  def self.signature(run)
    Digest::SHA256.hexdigest([ run.id, run.driver_id, run.assignment_version, run.status,
      run.visits.select(&:pending?).map { |visit| [ visit.id, visit.position, visit.customer_address, visit.customer.latitude, visit.customer.longitude,
        visit.customer.address, visit.customer.city, visit.delivery_orders.sort_by(&:id).map { |order| order.attributes.slice("id", "service_minutes", "preferred_time", "window_start", "window_end", "updated_at") } ] } ].to_json)
  end

  def self.call(run:, location:, now: Time.current)
    url = ENV["OSRM_URL"].presence
    return {} unless url && location.fresh? && location.accuracy <= 1000
    stops = run.visits.select(&:pending?).first(3)
    # A changed address invalidates the customer's old geocode.
    stops = stops.take_while { |stop| stop.customer.latitude && stop.customer.longitude && stop.customer_address == [ stop.customer.address, stop.customer.city ].compact.join(", ") }
    return {} if stops.empty?
    coords = [ [ location.longitude.to_f, location.latitude.to_f ], *stops.map { |stop| [ stop.customer.longitude.to_f, stop.customer.latitude.to_f ] } ]
    RouteOptimization::Dataset.validate_coverage!(coords)
    uri = URI.parse("#{url.delete_suffix('/')}/route/v1/driving/#{coords.map { |pair| pair.join(',') }.join(';')}?overview=false&steps=false&radiuses=#{coords.map { '1000' }.join(';')}")
    raise Unavailable unless uri.is_a?(URI::HTTP) && uri.host.present? && !uri.userinfo
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 3, write_timeout: 2) { |http| http.get(uri.request_uri) }
    raise Unavailable unless response.is_a?(Net::HTTPSuccess) && response.body.bytesize < 1_000_000
    body = JSON.parse(response.body)
    legs = body.dig("routes", 0, "legs")
    raise Unavailable unless body["code"] == "Ok" && legs.is_a?(Array) && legs.size == stops.size
    clock = now
    estimates = stops.zip(legs).map do |stop, leg|
      duration = Float(leg.fetch("duration"))
      raise Unavailable unless duration.finite? && duration.between?(0, 7.days.to_i)
      clock += duration
      orders = stop.delivery_orders.to_a
      starts = orders.filter_map { |order| local_time(run, order.window_start || order.preferred_time) }
      clock = [ clock, *starts ].max
      arrival = clock
      clock += orders.sum(&:service_minutes).minutes
      { visit_id: stop.id, arrival_at: arrival.iso8601 }
    end
    { run_id: run.id, signature: signature(run), calculated_at: now.iso8601, stops: estimates }
  rescue Osrm::Client::Error, URI::InvalidURIError, JSON::ParserError, KeyError, TypeError, ArgumentError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    raise Unavailable, error.class.name
  end

  def self.local_time(run, time)
    return unless time
    ActiveSupport::TimeZone[run.company.time_zone].local(run.scheduled_date.year, run.scheduled_date.month, run.scheduled_date.day, time.hour, time.min, time.sec)
  end
end
