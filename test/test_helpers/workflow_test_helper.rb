module WorkflowTestHelper
  def workflow_order(company: companies(:one), customer: nil, date: nil, rows: nil)
    customer ||= company.customers.active.first
    company.delivery_orders.create!(customer: customer, scheduled_date: date || company.local_date,
      delivery_order_items_attributes: rows || [ { description: "Pan", unit: "pack", quantity: 10 } ])
  end

  def workflow_plan(orders, driver: users(:driver))
    company = orders.first.company
    run = company.delivery_runs.new(name: "Prueba de seguimiento", scheduled_date: orders.first.scheduled_date, driver: driver, status: :assigned)
    DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: orders.map(&:id))
    run
  end

  def workflow_finish(visit, quantities: nil, status: "completed", driver: users(:driver))
    # Authorized offline work also lets tests exercise genuine past delivery dates.
    proof = { "visit_id" => visit.id, "expires_at" => 1.hour.from_now.to_i, "revision_version" => 3, "revision" => DriverWorkSnapshot.revision(visit) }
    DriverVisitRecorder.call(user: driver, visit_id: visit.id, offline_proof: proof, attributes: { status: status, notes: "Resultado de prueba",
      items: visit.delivery_items.order(:id).zip(quantities || []).map { |item, quantity| { id: item.id, delivered_quantity: quantity } } })
  end

  def workflow_report(visit = nil, **extra)
    IncidentRecorder.report(user: users(:driver), operation_id: SecureRandom.uuid,
      attributes: { visit_id: visit&.id, kind: "closed", description: "El local está cerrado", occurred_at: Time.current.iso8601 }.merge(extra))
  end
end
