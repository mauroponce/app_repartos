class CommercialOpportunitiesJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(company_id = nil, **_options) { "opportunities:#{company_id}" }, duration: 30.minutes
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5

  def perform(company_id = nil, force: false)
    unless company_id
      Company.find_each { |company| self.class.perform_later(company.id, force: true) }
      return
    end
    company = Company.find_by(id: company_id)
    return unless company
    return if !force && company.opportunities_evaluated_at && company.opportunities_changed_at && company.opportunities_evaluated_at >= company.opportunities_changed_at
    Time.use_zone(company.time_zone) { CommercialOpportunityDetector.new(company).call }
  end
end
