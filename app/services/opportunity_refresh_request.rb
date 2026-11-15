class OpportunityRefreshRequest
  def self.call(company_id)
    now = Time.current
    Company.where(id: company_id).update_all(opportunities_changed_at: now)
    claimed = Company.where(id: company_id).where("opportunities_job_enqueued_at IS NULL OR opportunities_job_enqueued_at < ?", 10.minutes.ago).update_all(opportunities_job_enqueued_at: now)
    CommercialOpportunitiesJob.perform_later(company_id) if claimed.positive?
  end
end
