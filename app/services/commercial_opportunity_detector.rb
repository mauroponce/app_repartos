require "set"

class CommercialOpportunityDetector
  def initialize(company, now: Time.current)
    @company, @now = company, now
    @today = now.in_time_zone(company.time_zone).to_date
    @settings = company.commercial_rule_setting || company.build_commercial_rule_setting
    @connection = ActiveRecord::Base.connection
  end

  def call
    evaluate_inactivity
    evaluate_decline
    evaluate_shortages
    evaluate_failures
    evaluate_unfollowed_partials
    @company.commercial_opportunities.where("last_evaluated_at < ?", @now).find_each do |record|
      @company.with_lock do
        record.reload
        next if record.last_evaluated_at >= @now
        attrs = { last_evaluated_at: @now }
        attrs.merge!(status: "cleared", state_changed_at: @now) if record.status.in?(%w[open snoozed])
        changed = attrs[:status] == "cleared"
        record.update!(attrs)
        event(record, "cleared", "La condición ya no se detecta") if changed
      end
    end
    @company.update_columns(opportunities_evaluated_at: @now)
  end

  private

  def orders
    @company.delivery_orders.where.not(status: :cancelled).where("scheduled_date <= ?", @today)
  end

  def evaluate_inactivity
    history = orders.select(:customer_id, "MAX(scheduled_date) AS last_on", "MIN(scheduled_date) AS first_on", "COUNT(DISTINCT scheduled_date) AS active_days").group(:customer_id).to_sql
    query(<<~SQL).each do |row|
      SELECT h.*, c.name,
        (SELECT COUNT(DISTINCT s.weekday) FROM delivery_schedules s WHERE s.company_id = c.company_id AND s.customer_id = c.id AND s.active AND s.starts_on <= #{q(@today)} AND (s.ends_on IS NULL OR s.ends_on >= #{q(@today)})) AS weekly
      FROM (#{history}) h JOIN customers c ON c.id = h.customer_id AND c.company_id = #{@company.id.to_i}
      WHERE c.status = 'active' AND NOT EXISTS (SELECT 1 FROM delivery_orders future WHERE future.company_id = c.company_id AND future.customer_id = c.id AND future.status = 'pending' AND future.scheduled_date > #{q(@today)})
    SQL
      last = Date.parse(row.fetch("last_on").to_s)
      days = row["active_days"].to_i
      observed = days > 1 ? (last - Date.parse(row["first_on"].to_s)).to_f / (days - 1) : @settings.inactivity_min_days
      expected = row["weekly"].to_i.positive? ? [ observed, 7.0 / row["weekly"].to_i ].min : observed
      threshold = [ @settings.inactivity_min_days, (expected * @settings.inactivity_multiplier).ceil ].max
      age = (@today - last).to_i
      next if age < threshold
      persist("inactive", "customer:#{row['customer_id']}", customer_id: row["customer_id"], title: "Contactar a #{row['name']}: lleva #{age} días sin pedidos".first(255),
        evidence: { last_order_on: last, days_without_orders: age, expected_interval_days: expected.round(1), threshold_days: threshold, historical_order_days: days, recurring_weekly: row["weekly"].to_i }, condition: last.to_s)
    end
  end

  def evaluate_decline
    length = @settings.comparison_days
    start = @today - length + 1
    previous_start = start - length
    relation = orders.where(scheduled_date: previous_start..@today)
    sql = relation.select(:customer_id, "COUNT(*) FILTER (WHERE scheduled_date >= #{q(start)}) AS current_count", "COUNT(*) FILTER (WHERE scheduled_date < #{q(start)}) AS previous_count").group(:customer_id).to_sql
    query("SELECT h.*, c.name FROM (#{sql}) h JOIN customers c ON c.id = h.customer_id AND c.company_id = #{@company.id.to_i} WHERE c.status = 'active'").each do |row|
      current, previous = row.values_at("current_count", "previous_count").map(&:to_i)
      next if previous < @settings.decline_min_orders
      drop = ((previous - current) * 100.0 / previous).round(1)
      next if drop < @settings.decline_percent
      persist("decline", "customer:#{row['customer_id']}", customer_id: row["customer_id"], title: "Revisar disminución de pedidos de #{row['name']}".first(255),
        evidence: { current_orders: current, previous_orders: previous, decline_percent: drop, threshold_percent: @settings.decline_percent, current_from: start, current_until: @today, previous_from: previous_start, previous_until: start - 1 }, condition: (drop / 20).floor)
    end
  end

  def evaluate_shortages
    report = DeliveryReports.new(ReportFilter.new(@company, start_on: @today - @settings.comparison_days + 1, end_on: @today))
    query(<<~SQL).each do |row|
      WITH evaluated AS (#{report.facts_scope.to_sql})
      SELECT oi.product_id, MAX(oi.description) AS name, oi.unit, COUNT(DISTINCT f.id) AS affected_orders,
        SUM(oi.quantity - di.delivered_quantity) AS missing,
        (ARRAY_AGG(DISTINCT f.customer_id))[1:30] AS customer_ids, (ARRAY_AGG(DISTINCT f.id))[1:50] AS order_ids
      FROM evaluated f JOIN delivery_order_items oi ON oi.delivery_order_id = f.id AND oi.company_id = f.company_id
      JOIN delivery_items di ON di.delivery_order_item_id = oi.id AND di.visit_id = f.visit_id AND di.company_id = oi.company_id
      WHERE f.visit_status <> 'pending' AND oi.product_id IS NOT NULL AND di.delivered_quantity < oi.quantity
      GROUP BY oi.product_id, oi.unit HAVING COUNT(DISTINCT f.id) >= #{@settings.shortage_min_orders.to_i}
    SQL
      persist("shortage", "product:#{row['product_id']}:#{row['unit']}", product_id: row["product_id"], title: "Revisar faltantes de #{row['name']}: #{row['affected_orders']} pedidos afectados".first(255),
        evidence: { affected_orders: row["affected_orders"].to_i, missing: row["missing"].to_s, unit: row["unit"], customer_ids: array(row["customer_ids"]), order_ids: array(row["order_ids"]), threshold_orders: @settings.shortage_min_orders, from: @today - @settings.comparison_days + 1, until: @today }, condition: row["affected_orders"].to_i / @settings.shortage_min_orders)
    end
  end

  def evaluate_failures
    report = DeliveryReports.new(ReportFilter.new(@company, start_on: @today - @settings.comparison_days + 1, end_on: @today))
    query(<<~SQL).each do |row|
      WITH evaluated AS (#{report.facts_scope.to_sql})
      SELECT f.customer_id, MAX(f.customer_name) AS name, COUNT(DISTINCT f.visit_id) AS failures, COUNT(*) AS affected_orders,
        (ARRAY_AGG(DISTINCT f.id))[1:50] AS order_ids, (ARRAY_AGG(DISTINCT f.scheduled_date))[1:30] AS dates,
        ARRAY_AGG(DISTINCT COALESCE(v.failure_reason, CASE WHEN v.status = 'completed' THEN 'no_quantity_delivered' ELSE v.status END)) AS reasons
      FROM evaluated f JOIN visits v ON v.id = f.visit_id AND v.company_id = f.company_id
      WHERE f.outcome = 'failed' GROUP BY f.customer_id HAVING COUNT(DISTINCT f.visit_id) >= #{@settings.failure_min_orders.to_i}
    SQL
      persist("repeated_failure", "customer:#{row['customer_id']}", customer_id: row["customer_id"], title: "Revisar entregas fallidas de #{row['name']}".first(255),
        evidence: { failed_visits: row["failures"].to_i, failed_orders: row["affected_orders"].to_i, dates: array(row["dates"]), reasons: array(row["reasons"]), order_ids: array(row["order_ids"]), threshold_orders: @settings.failure_min_orders, period_days: @settings.comparison_days }, condition: row["failures"].to_i / @settings.failure_min_orders)
    end
  end

  def evaluate_unfollowed_partials
    zone = @connection.quote(ActiveSupport::TimeZone[@company.time_zone].tzinfo.identifier)
    execution_day = "COALESCE(DATE(COALESCE(visits.recorded_at, visits.confirmed_at, visits.completed_at) AT TIME ZONE 'UTC' AT TIME ZONE #{zone}), delivery_orders.scheduled_date)"
    relation = @company.delivery_orders.joins(:visit).where(status: :needs_attention).where("#{execution_day} <= ?", @today - @settings.partial_grace_days)
      .where.not(id: @company.delivery_orders.where.not(status: :cancelled).where.not(rescheduled_from_id: nil).select(:rescheduled_from_id))
      .where(<<~SQL)
        NOT EXISTS (SELECT 1 FROM workflow_tasks t WHERE t.company_id = delivery_orders.company_id AND t.status <> 'cancelled' AND
          (t.delivery_order_id = delivery_orders.id OR t.incident_id IN (SELECT id FROM incidents WHERE company_id = delivery_orders.company_id AND visit_id = delivery_orders.visit_id)
           OR t.commercial_opportunity_id IN (SELECT id FROM commercial_opportunities WHERE company_id = delivery_orders.company_id AND delivery_order_id = delivery_orders.id)))
      SQL
    relation.includes(:customer, :visit, delivery_order_items: :delivery_item).find_each(batch_size: 100) do |order|
      next unless order.visit&.completed?
      items = order.delivery_order_items.to_a
      next if items.empty? || items.any? { |item| item.delivery_item&.delivered_quantity.nil? || item.delivery_item.visit_id != order.visit_id }
      next unless items.any? { |item| item.delivery_item.delivered_quantity.positive? } && items.any? { |item| item.remaining_quantity.positive? }
      missing = items.filter_map { |item| { description: item.description, product_id: item.product_id, unit: item.unit, missing: item.remaining_quantity.to_s } if item.remaining_quantity.positive? }
      persist("unfollowed_partial", "order:#{order.id}", customer_id: order.customer_id, delivery_order_id: order.id, title: "Dar seguimiento a entrega parcial ##{order.id} · #{order.customer_name}".first(255),
        evidence: { order_ids: [ order.id ], scheduled_on: order.scheduled_date, execution_at: order.visit.recorded_at || order.visit.confirmed_at || order.visit.completed_at, missing_lines: missing, grace_days: @settings.partial_grace_days }, condition: order.id)
    end
  end

  def persist(rule, suffix, customer_id: nil, product_id: nil, delivery_order_id: nil, title:, evidence:, condition:)
    key = "#{rule}:#{suffix}"
    fingerprint = Digest::SHA256.hexdigest([ rule, suffix, condition ].to_json)
    @company.with_lock do
      record = @company.commercial_opportunities.find_or_initialize_by(stable_key: key)
      action = record.new_record? ? "detected" : nil
      if record.persisted? && record.status != "open"
        reopen = record.status == "cleared" || (record.status == "snoozed" ? record.snoozed_until && record.snoozed_until <= @now : record.acknowledged_fingerprint != fingerprint || record.state_changed_at <= @now - @settings.cooldown_days.days)
        if reopen
          record.assign_attributes(status: "open", generation: record.generation + 1, state_changed_at: @now, snoozed_until: nil)
          action = "reopened"
        end
      end
      record.assign_attributes(rule: rule, customer_id: customer_id, product_id: product_id, delivery_order_id: delivery_order_id,
        title: title, evidence: evidence, fingerprint: fingerprint, last_evaluated_at: @now)
      record.detected_at ||= @now
      record.state_changed_at ||= @now
      record.save!
      event(record, action, title, evidence) if action
      if record.status == "open" && @settings.automatic_rules.include?(rule) && @settings.auto_assignee&.active? && @settings.auto_assignee.manages_customers?
        source = "opportunity:#{record.id}:#{record.generation}"
        already_followed = record.workflow_tasks.unfinished.exists? ||
          record.workflow_tasks.where("created_at >= ? OR closed_at >= ?", record.state_changed_at, record.state_changed_at).exists?
        unless already_followed || record.workflow_tasks.exists?(source_key: source)
          task = WorkflowActions.new(@settings.auto_assignee).build_task({ title: title, description: "Regla automática: #{CommercialOpportunity::RULES.fetch(rule)}. Revisá la evidencia de la oportunidad ##{record.id}.",
            category: "commercial", priority: "normal", commercial_opportunity_id: record.id, assignee_id: @settings.auto_assignee_id }, source, system: true)
          event(record, "task_created", "Tarea automática creada", { task_id: task.id })
        end
      end
    end
  end

  def event(record, action, message, changes = {})
    @company.workflow_events.create!(commercial_opportunity: record, action: action, message: message, changeset: changes)
  end

  def q(value)
    @connection.quote(value)
  end

  def query(sql)
    @connection.select_all(sql).to_a
  end

  def array(value)
    return value if value.is_a?(Array)
    value.to_s.delete_prefix("{").delete_suffix("}").split(",").map { |entry| entry.delete_prefix('"').delete_suffix('"') }
  end
end
