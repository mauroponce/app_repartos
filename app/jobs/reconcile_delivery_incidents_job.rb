class ReconcileDeliveryIncidentsJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(company_id = nil) { "incidents:#{company_id}" }, duration: 30.minutes

  def perform(company_id = nil)
    unless company_id
      Company.find_each { |company| self.class.perform_later(company.id) }
      return
    end
    company = Company.find_by(id: company_id)
    return unless company
    company.visits.joins(:delivery_run).where.not(status: :pending)
      .where(delivery_runs: { scheduled_date: (company.local_date - 90)..company.local_date })
      .where.not(id: company.incidents.where.not(visit_id: nil).select(:visit_id))
      .includes(:confirmed_by, :customer, :delivery_orders, :delivery_items, delivery_run: :driver).find_each(batch_size: 100) do |visit|
      IncidentRecorder.from_visit(visit)
    end
  end
end
