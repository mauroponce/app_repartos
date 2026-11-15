class DeliveryValuation
  def initialize(items)
    @items = items.to_a
  end

  def requested_value
    total(:unit_price, :requested)
  end

  def delivered_value
    total(:unit_price, :delivered)
  end

  def delivered_cost
    total(:unit_cost, :delivered)
  end

  def estimated_margin
    revenue, cost = delivered_value, delivered_cost
    revenue && cost && revenue - cost
  end

  def currency
    currencies = @items.map(&:currency).uniq
    currencies.one? ? currencies.first : nil
  end

  private

  def total(value, quantity)
    return nil if @items.empty? || currency.nil?
    rows = @items.map do |item|
      amount = item.public_send(value)
      count = if quantity == :requested
        item.is_a?(DeliveryOrderItem) ? item.quantity : item.planned_quantity
      else
        item.is_a?(DeliveryOrderItem) ? item.delivery_item&.delivered_quantity : item.delivered_quantity
      end
      return nil if amount.nil? || count.nil?
      amount * count
    end
    rows.sum(0.to_d)
  end
end
