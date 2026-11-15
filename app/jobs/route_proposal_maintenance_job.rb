class RouteProposalMaintenanceJob < ApplicationJob
  queue_as :default

  def perform(company_id = nil)
    unless company_id
      Company.find_each { |company| self.class.perform_later(company.id) }
      return
    end
    company = Company.find_by(id: company_id)
    return unless company
    if (dataset = RouteOptimization::Dataset.identity)
      company.route_publications.where(state: "ready").joins(:proposal)
        .where("route_optimization_proposals.result->>'dataset_identity' IS DISTINCT FROM ?", dataset).find_each do |publication|
        company.with_lock do
          publication.reload
          run = company.delivery_runs.find(publication.delivery_run_id)
          next unless publication.state == "ready" && run.editable?
          publication.update!(state: "pending", proposal: nil, error_message: nil)
          run.update_columns(assignment_version: run.assignment_version + 1)
          PrepareRoutePublicationJob.perform_later(company.id, run.id)
        end
      end
    end
    company.route_publications.where(state: "pending").where("updated_at < ?", 5.minutes.ago).find_each do |publication|
      company.with_lock do
        publication.reload
        next unless publication.state == "pending"
        if publication.stalled?
          publication.update!(state: "failed", error_message: "El cálculo venció o no pudo iniciarse. Reintentá la optimización o publicá el orden manual.")
        else
          PrepareRoutePublicationJob.perform_later(company.id, publication.delivery_run_id)
        end
      end
    end
    company.route_optimization_proposals.where(status: %w[queued processing ready]).where("expires_at <= ?", Time.current).in_batches.update_all(status: "expired", updated_at: Time.current)
    company.route_optimization_proposals.where(status: %w[queued processing]).where("updated_at < ? AND expires_at > ?", 5.minutes.ago, Time.current).find_each do |proposal|
      OptimizeDeliveryRunJob.perform_later(company.id, proposal.id)
    end
    company.routing_cache_entries.where("last_used_at < ?", 90.days.ago).in_batches.delete_all
  end
end
