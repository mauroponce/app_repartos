require "test_helper"
require_relative "../test_helpers/workflow_test_helper"

class CommercialOpportunitiesJobTest < ActiveJob::TestCase
  include WorkflowTestHelper
  test "retries preserve alert identity and scheduled fanout uses tenant IDs" do
    company = companies(:one)
    [ 30, 37, 44 ].each { |days| workflow_order(date: company.local_date - days) }
    CommercialOpportunitiesJob.perform_now(company.id, force: true)
    ids = company.commercial_opportunities.order(:id).pluck(:id)
    assert ids.any?
    CommercialOpportunitiesJob.perform_now(company.id, force: true)
    assert_equal ids, company.commercial_opportunities.order(:id).pluck(:id)
    assert_not_nil company.reload.opportunities_evaluated_at
    assert_empty companies(:two).commercial_opportunities
    assert_enqueued_with(job: CommercialOpportunitiesJob, args: [ company.id, { force: true } ]) { CommercialOpportunitiesJob.perform_now }
  end

  test "reconciliation detects old known failures without changing execution or creating duplicates" do
    order = workflow_order
    run = workflow_plan([ order ])
    visit = run.visits.first
    visit.update_columns(status: "closed")
    original = visit.reload.attributes
    ReconcileDeliveryIncidentsJob.perform_now(order.company_id)
    assert_equal 1, order.company.incidents.where(visit_id: visit.id).count
    ReconcileDeliveryIncidentsJob.perform_now(order.company_id)
    assert_equal 1, order.company.incidents.where(visit_id: visit.id).count
    assert_equal original, visit.reload.attributes
    assert_nil order.company.incidents.sole.reporter
    assert_nil order.company.incidents.sole.occurred_at
  end
end
