require "test_helper"
require_relative "../test_helpers/single_route_test_helper"

class RouteProposalMaintenanceJobTest < ActiveSupport::TestCase
  include SingleRouteTestHelper
  include ActiveJob::TestHelper

  test "maintenance expires old proposals and retries interrupted calculations within their own tenant" do
    run = single_route
    proposal = RouteOptimizationProposal.request!(user: users(:one), run: run)
    proposal.update_columns(updated_at: 6.minutes.ago)
    assert_enqueued_with(job: OptimizeDeliveryRunJob, args: [ run.company_id, proposal.id ]) { RouteProposalMaintenanceJob.perform_now(run.company_id) }
    proposal.update_columns(expires_at: 1.second.ago)
    RouteProposalMaintenanceJob.perform_now(companies(:two).id)
    assert_equal "queued", proposal.reload.status
    RouteProposalMaintenanceJob.perform_now(run.company_id)
    assert_equal "expired", proposal.reload.status
  end
end
