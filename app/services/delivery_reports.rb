class DeliveryReports
  OUTCOMES = { "full" => "Completas", "partial" => "Parciales", "failed" => "Fallidas", "pending" => "Pendientes", "unknown" => "Sin cantidades suficientes" }.freeze
  attr_reader :filter

  def initialize(filter)
    @filter = filter
  end

  def counts
    @counts ||= begin
      grouped = query(facts_scope.reselect("outcome, COUNT(*) AS total").group("outcome")).to_h { |row| [ row["outcome"], row["total"].to_i ] }
      grouped = OUTCOMES.keys.index_with { |key| grouped.fetch(key, 0) }
      resolved = grouped.values_at("full", "partial", "failed").sum
      active_customers = filter.orders.distinct.count(:customer_id)
      customers = filter.company.customers
      customers = customers.where(id: filter.customer_id) if filter.customer_id
      {
        programmed: grouped.values.sum, visits: filter.visits.where.not(status: :pending).count,
        complete: grouped["full"], partial: grouped["partial"], failed: grouped["failed"], pending: grouped["pending"], unknown: grouped["unknown"], resolved: resolved,
        fulfillment: resolved.zero? ? nil : (grouped["full"] * 100.0 / resolved).round(1),
        active_customers: active_customers, inactive_customers: [ customers.count - active_customers, 0 ].max,
        commercial_tasks: commercial_tasks.count, distribution: grouped
      }
    end
  end

  def commercial_tasks
    relation = filter.company.workflow_tasks.unfinished.where(category: "commercial")
    relation = relation.where(customer_id: filter.customer_id) if filter.customer_id
    relation = relation.where(commercial_opportunity_id: filter.company.commercial_opportunities.where(product_id: filter.product_id).select(:id)) if filter.product_id
    relation
  end

  def daily
    query(facts_scope.reselect("scheduled_date::text AS day, outcome, COUNT(*) AS total").group("scheduled_date, outcome").order("scheduled_date"))
  end

  def drivers
    relation = facts_scope.joins("LEFT JOIN users u ON u.id = facts.driver_id AND u.company_id = facts.company_id")
      .where(facts: { outcome: %w[full partial failed] })
      .reselect("facts.driver_id, COALESCE(u.name, 'Autoría de reparto desconocida') AS name, COUNT(*) FILTER (WHERE outcome = 'full') AS full, COUNT(*) FILTER (WHERE outcome = 'partial') AS partial, COUNT(*) FILTER (WHERE outcome = 'failed') AS failed")
      .group("facts.driver_id, u.name").order(Arel.sql("3 DESC, name")).limit(20)
    query(relation)
  end

  def shortages
    relation = facts_scope.joins("JOIN delivery_order_items oi ON oi.delivery_order_id = facts.id AND oi.company_id = facts.company_id JOIN delivery_items di ON di.delivery_order_item_id = oi.id AND di.visit_id = facts.visit_id AND di.company_id = oi.company_id")
      .where("facts.visit_status <> 'pending' AND di.delivered_quantity < oi.quantity")
      .reselect("oi.product_id, MAX(oi.description) AS description, oi.unit, COUNT(DISTINCT facts.id) AS orders, COUNT(DISTINCT facts.customer_id) AS customers, SUM(GREATEST(oi.quantity - di.delivered_quantity, 0)) AS missing")
      .group("oi.product_id, CASE WHEN oi.product_id IS NULL THEN oi.description ELSE NULL END, oi.unit")
      .order(Arel.sql("orders DESC, description")).limit(30)
    relation = relation.where(oi: { product_id: filter.product_id }) if filter.product_id
    query(relation)
  end

  def problematic_customers
    query(facts_scope.where(facts: { outcome: %w[partial failed] }).reselect("customer_id, MAX(customer_name) AS name, COUNT(*) AS total").group("customer_id").order(Arel.sql("total DESC, name")).limit(20))
  end

  def incident_ranking
    filter.incidents.group(:kind).count.sort_by { |_, count| -count }
  end

  def details(outcome: nil, page: 1)
    relation = facts_scope.order(Arel.sql("scheduled_date DESC, id DESC")).limit(25).offset((page.to_i.clamp(1, 100_000) - 1) * 25)
    relation = relation.where(facts: { outcome: outcome }) if OUTCOMES.key?(outcome)
    query(relation)
  end

  # All value-bearing predicates remain Active Record relations. SQL fragments
  # below are fixed expressions; no request parameter becomes SQL syntax.
  def facts_scope
    lines = DeliveryOrderItem.unscoped.from("delivery_order_items oi")
      .joins("JOIN eligible o ON o.id = oi.delivery_order_id AND o.company_id = oi.company_id LEFT JOIN delivery_items di ON di.delivery_order_item_id = oi.id AND di.company_id = oi.company_id")
      .select("oi.delivery_order_id, COUNT(*) AS lines, COUNT(di.delivered_quantity) FILTER (WHERE di.visit_id = o.visit_id) AS known, COUNT(*) FILTER (WHERE di.visit_id = o.visit_id AND di.delivered_quantity < oi.quantity) AS shortages, COUNT(*) FILTER (WHERE di.visit_id = o.visit_id AND di.delivered_quantity > 0) AS positive")
      .group("oi.delivery_order_id")
    facts = DeliveryOrder.unscoped.from("eligible o")
      .joins("LEFT JOIN visits v ON v.id = o.visit_id AND v.company_id = o.company_id LEFT JOIN delivery_runs r ON r.id = v.delivery_run_id AND r.company_id = o.company_id LEFT JOIN users actor ON actor.id = v.confirmed_by_id AND actor.company_id = o.company_id LEFT JOIN line_stats ls ON ls.delivery_order_id = o.id")
      .select(<<~SQL)
        o.id, o.company_id, o.customer_id, o.customer_name, o.scheduled_date, o.visit_id, v.status AS visit_status, v.delivery_run_id AS run_id,
        CASE WHEN v.status IS NULL OR v.status = 'pending' THEN r.driver_id WHEN actor.role = 'driver' THEN v.confirmed_by_id END AS driver_id,
        CASE WHEN v.id IS NULL THEN CASE WHEN o.status = 'pending' THEN 'pending' ELSE 'unknown' END
          WHEN v.status = 'pending' THEN 'pending' WHEN v.status <> 'completed' THEN 'failed'
          WHEN COALESCE(ls.lines, 0) = 0 OR ls.known < ls.lines THEN 'unknown'
          WHEN ls.shortages = 0 THEN 'full' WHEN ls.positive > 0 THEN 'partial' ELSE 'failed' END AS outcome
      SQL
    DeliveryOrder.unscoped.with(eligible: filter.orders, line_stats: lines, facts: facts).from("facts").select("facts.*")
  end

  private

  def query(relation)
    ActiveRecord::Base.connection.select_all(relation.to_sql, "Reportes de entregas").to_a
  end
end
