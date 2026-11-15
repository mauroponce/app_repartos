module WorkflowsHelper
  def workflow_select_data(key)
    kind = { customer_id: "customer", product_id: "product", run_id: "route", delivery_run_id: "route", driver_id: "driver", assigned_to_id: "manager", assignee_id: "staff", auto_assignee_id: "manager" }.fetch(key.to_sym)
    { controller: "workflow-select", workflow_select_kind_value: kind, workflow_select_url_value: workflow_lookup_path }
  end

  def workflow_change_value(field, raw, names)
    values = raw.is_a?(Array) ? raw : [ raw ]
    values.map do |value|
      if value.nil?
        "Sin informar"
      elsif field.end_with?("_id")
        names[value.to_i] || "Usuario ##{value}"
      elsif field == "priority"
        Incident::PRIORITIES[value] || value
      elsif field == "category"
        WorkflowTask::CATEGORIES[value] || value
      elsif field == "visit_status"
        operation_status(value)
      elsif field == "status"
        Incident::STATUSES.merge(WorkflowTask::STATUSES).merge(CommercialOpportunity::STATUSES)[value] || value
      elsif field.end_with?("_at")
        workflow_date(Time.iso8601(value.to_s))
      else
        value
      end
    end.join(" → ")
  end

  def workflow_date(value)
    value ? l(value.in_time_zone(Current.company.time_zone), format: :short) : "Sin informar"
  end

  def workflow_badge(record)
    labels = record.class::STATUSES
    tag.span(labels.fetch(record.status), class: "workflow-badge #{record.status}")
  end

  def workflow_counts
    @workflow_counts ||= { incidents: Current.company.incidents.unresolved.count,
      tasks: Current.company.workflow_tasks.unfinished.count,
      opportunities: Current.company.commercial_opportunities.where(status: "open").count }
  end

  def workflow_evidence_label(key)
    { "last_order_on" => "Último pedido", "days_without_orders" => "Días sin pedidos", "expected_interval_days" => "Frecuencia esperada (días)", "threshold_days" => "Umbral (días)", "historical_order_days" => "Días con pedidos históricos", "recurring_weekly" => "Días de programación por semana", "current_orders" => "Pedidos del período actual", "previous_orders" => "Pedidos del período anterior", "decline_percent" => "Disminución (%)", "threshold_percent" => "Umbral de disminución (%)", "current_from" => "Inicio actual", "current_until" => "Fin actual", "previous_from" => "Inicio anterior", "previous_until" => "Fin anterior", "affected_orders" => "Pedidos afectados", "missing" => "Cantidad faltante", "unit" => "Unidad", "threshold_orders" => "Umbral de pedidos", "from" => "Desde", "until" => "Hasta", "failed_orders" => "Pedidos afectados", "failed_visits" => "Visitas con pedidos fallidos", "dates" => "Fechas", "reasons" => "Motivos", "period_days" => "Período (días)", "scheduled_on" => "Fecha del pedido", "execution_at" => "Fecha de ejecución (si se conoce)", "grace_days" => "Espera para seguimiento (días)", "missing_lines" => "Productos pendientes" }.fetch(key, key)
  end

  def workflow_evidence_value(key, value)
    return "Sin informar" if value.nil?
    if key == "execution_at"
      workflow_date(Time.iso8601(value.to_s))
    elsif key == "missing"
      quantity_text(value.to_d)
    elsif key == "unit"
      DeliveryUnits::LABELS.fetch(value, value)
    elsif key == "reasons"
      Array(value).map { |reason| (reason == "no_quantity_delivered" ? "Sin mercadería entregada" : nil) || Visit::FAILURE_REASONS[reason] || Incident::KINDS[reason] || operation_status(reason) }.join(", ")
    elsif key == "missing_lines"
      Array(value).map { |row| "#{row['description']}: #{quantity_text(row['missing'].to_d)} #{DeliveryUnits::LABELS[row['unit']]}" }.join("; ")
    else
      value.is_a?(Array) ? value.join(", ") : value.to_s
    end
  end
end
