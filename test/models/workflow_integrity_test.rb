require "test_helper"
require_relative "../test_helpers/workflow_test_helper"

class WorkflowIntegrityTest < ActiveSupport::TestCase
  include WorkflowTestHelper
  include ActionCable::TestHelper

  test "workflow broadcasts contain only invalidations and never target another company or driver" do
    company, driver = companies(:one), users(:driver)
    own = Turbo::StreamsChannel.verified_stream_name(Turbo::StreamsChannel.signed_stream_name([ company, "user_#{driver.id}", :workflow_driver ]))
    foreign = Turbo::StreamsChannel.verified_stream_name(Turbo::StreamsChannel.signed_stream_name([ companies(:two), "user_#{users(:other_driver).id}", :workflow_driver ]))
    assert_broadcasts(foreign, 0) do
      assert_broadcasts(own, 2) do
        WorkflowActions.new(users(:one)).create_task(operation_id: SecureRandom.uuid, attributes: { title: "Instrucción privada del cliente", description: "Detalle sensible", category: "operational", assignee_id: driver.id })
      end
    end
    assert broadcasts(own).all? { |payload| payload.include?("workflow_refresh") && !payload.include?("sensible") && !payload.include?("cliente") }
  end

  test "commercial notices remain inaccessible when a former manager becomes a driver" do
    result = WorkflowActions.new(users(:one)).create_task(operation_id: SecureRandom.uuid, attributes: { title: "Gestión comercial privada", category: "commercial", assignee_id: users(:supervisor).id })
    user = users(:supervisor)
    user.update!(role: :driver)
    assert_empty DriverInbox.new(user).notices
    assert_empty DriverInbox.new(user).tasks
    assert WorkflowTask.find(result.fetch("task_id"))
  end

  test "one failed visit with several orders is not a repeated failure" do
    company = companies(:one)
    company.create_commercial_rule_setting!(failure_min_orders: 2)
    orders = [ workflow_order, workflow_order ]
    run = workflow_plan(orders)
    workflow_finish(run.visits.first, status: "closed")
    CommercialOpportunityDetector.new(company).call
    assert_equal 1, company.incidents.count
    assert_equal 2, DeliveryReports.new(ReportFilter.new(company)).counts[:failed]
    assert_not company.commercial_opportunities.exists?(rule: "repeated_failure")
  end
end
