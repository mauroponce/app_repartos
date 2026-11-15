class DeliveryMetrics
  def self.call(orders)
    eligible = orders.reject(&:cancelled?)
    closed = eligible.count(&:closed?)
    full = eligible.count(&:fully_delivered?)
    { eligible: eligible.size, closed: closed, fully_delivered: full,
      closure_rate: eligible.empty? ? nil : (closed.to_d * 100 / eligible.size).round(2),
      full_delivery_rate: eligible.empty? ? nil : (full.to_d * 100 / eligible.size).round(2) }
  end
end
