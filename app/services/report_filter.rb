class ReportFilter
  attr_reader :company, :start_on, :end_on, :driver_id, :customer_id, :run_id, :product_id
  def initialize(company, values = {})
    @company = company
    values = values.to_h.symbolize_keys
    days = values[:period].to_s.in?(%w[7 30 90]) ? values[:period].to_i : 30
    @end_on = values[:end_on].present? ? Date.iso8601(values[:end_on].to_s) : company.local_date
    @start_on = values[:start_on].present? ? Date.iso8601(values[:start_on].to_s) : @end_on - days + 1
    raise ArgumentError, "El rango debe tener entre 1 y 366 días" unless (@end_on - @start_on).to_i.between?(0, 365)
    @driver_id = company.users.where(role: :driver).find(values[:driver_id]).id if values[:driver_id].present?
    @customer_id = company.customers.find(values[:customer_id]).id if values[:customer_id].present?
    @run_id = company.delivery_runs.find(values[:run_id]).id if values[:run_id].present?
    @product_id = company.products.find(values[:product_id]).id if values[:product_id].present?
  end

  def previous
    length = (end_on - start_on).to_i + 1
    self.class.new(company, to_h.merge(start_on: start_on - length, end_on: start_on - 1))
  end

  def to_h
    { start_on: start_on.to_s, end_on: end_on.to_s, driver_id: driver_id, customer_id: customer_id, run_id: run_id, product_id: product_id }.compact
  end

  def orders
    relation = company.delivery_orders.where.not(status: :cancelled).where(scheduled_date: start_on..end_on)
    relation = relation.where(customer_id: customer_id) if customer_id
    relation = relation.joins(:visit).where(visits: { delivery_run_id: run_id }) if run_id
    if driver_id
      relation = relation.left_joins(visit: :delivery_run).where("(visits.status <> 'pending' AND visits.confirmed_by_id = :id) OR ((visits.id IS NULL OR visits.status = 'pending') AND delivery_runs.driver_id = :id)", id: driver_id)
    end
    relation = relation.where(id: company.delivery_order_items.where(product_id: product_id).select(:delivery_order_id)) if product_id
    relation
  end

  def visits
    relation = company.visits.joins(:delivery_run).where(delivery_runs: { scheduled_date: start_on..end_on })
    relation = relation.where(customer_id: customer_id) if customer_id
    relation = relation.where(delivery_run_id: run_id) if run_id
    relation = relation.where("(visits.status <> 'pending' AND visits.confirmed_by_id = :id) OR (visits.status = 'pending' AND delivery_runs.driver_id = :id)", id: driver_id) if driver_id
    relation = relation.where(id: company.delivery_items.where(product_id: product_id).select(:visit_id)) if product_id
    relation
  end

  def incidents
    from = start_on.in_time_zone(company.time_zone).beginning_of_day
    until_time = (end_on + 1).in_time_zone(company.time_zone).beginning_of_day
    relation = company.incidents.where("COALESCE(incidents.occurred_at, incidents.created_at) >= ? AND COALESCE(incidents.occurred_at, incidents.created_at) < ?", from, until_time)
    relation = relation.where(customer_id: customer_id) if customer_id
    relation = relation.where(driver_id: driver_id) if driver_id
    relation = relation.where(delivery_run_id: run_id) if run_id
    relation = relation.where(visit_id: company.delivery_items.where(product_id: product_id).select(:visit_id)) if product_id
    relation
  end
end
