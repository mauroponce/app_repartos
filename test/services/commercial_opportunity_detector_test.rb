require "test_helper"
require_relative "../test_helpers/workflow_test_helper"

class CommercialOpportunityDetectorTest < ActiveSupport::TestCase
  include WorkflowTestHelper
  setup do
    @company, @customer = companies(:one), customers(:one)
    @settings = @company.create_commercial_rule_setting!(inactivity_min_days: 14, inactivity_multiplier: 2, comparison_days: 30, decline_min_orders: 3, shortage_min_orders: 2, failure_min_orders: 2)
  end

  def detect
    CommercialOpportunityDetector.new(@company).call
  end

  test "inactivity uses observed frequency and recurring schedules without flagging customers who never ordered" do
    [ 56, 49, 42, 35 ].each { |days| workflow_order(date: @company.local_date - days) }
    new_customer = @company.customers.create!(name: "Cliente nuevo", phone: "123", address: "Nueva 1", city: "Ciudad")
    detect
    alerts = @company.commercial_opportunities.where(rule: "inactive")
    assert_equal [ @customer.id ], alerts.pluck(:customer_id)
    assert_equal 14, alerts.sole.evidence["threshold_days"]
    assert_not @company.commercial_opportunities.exists?(customer: new_customer)
    count = @company.commercial_opportunities.count
    detect
    assert_equal count, @company.commercial_opportunities.count
    assert_equal 35, alerts.sole.evidence["days_without_orders"]
  end

  test "active recurring weekdays refine slow historical frequency without counting same day schedules twice" do
    @settings.update!(inactivity_min_days: 1)
    @company.delivery_schedules.where(customer: @customer).update_all(active: false)
    [ 100, 40 ].each { |days| workflow_order(date: @company.local_date - days) }
    detect
    assert_not @company.commercial_opportunities.exists?(rule: "inactive")
    2.times { @company.delivery_schedules.create!(customer: @customer, weekday: 1, starts_on: @company.local_date - 180) }
    detect
    record = @company.commercial_opportunities.where(rule: "inactive").sole
    assert_equal 14, record.evidence["threshold_days"]
    assert_equal 1, record.evidence["recurring_weekly"]
  end

  test "decline compares equal windows and stored evidence is based on orders not money" do
    [ 35, 40, 45, 50 ].each { |days| workflow_order(date: @company.local_date - days) }
    workflow_order(date: @company.local_date - 2)
    detect
    record = @company.commercial_opportunities.where(rule: "decline").sole
    assert_equal 4, record.evidence["previous_orders"]
    assert_equal 1, record.evidence["current_orders"]
    assert_equal 75.0, record.evidence["decline_percent"]
    assert_equal 29, Date.parse(record.evidence["current_until"]) - Date.parse(record.evidence["current_from"])
    assert_no_match(/facturaci|margen|pesos|dólares/i, record.title)
  end

  test "shortages repeated failures and unfollowed partials link real evidence and recoveries suppress unfollowed alerts" do
    2.times do |index|
      order = workflow_order(date: @company.local_date - index - 3, rows: [ { product: products(:bread), quantity: 10 } ])
      run = workflow_plan([ order ])
      travel_to((@company.local_date - index - 3).in_time_zone(@company.time_zone).change(hour: 10)) { workflow_finish(run.visits.first, quantities: [ 4 ]) }
    end
    2.times do |index|
      order = workflow_order(date: @company.local_date - index - 3)
      workflow_finish(workflow_plan([ order ]).visits.first, status: "closed")
    end
    detect
    shortage = @company.commercial_opportunities.where(rule: "shortage").sole
    assert_equal 12.to_d, shortage.evidence["missing"].to_d
    assert_equal "pack", shortage.evidence["unit"]
    assert_equal 2, shortage.evidence["affected_orders"]
    failure = @company.commercial_opportunities.where(rule: "repeated_failure").sole
    assert_equal 2, failure.evidence["failed_orders"]
    partials = @company.commercial_opportunities.where(rule: "unfollowed_partial")
    assert_equal 2, partials.count
    order = partials.first.delivery_order
    DeliveryOrderRescheduler.call(company: @company, order_id: order.id, date: @company.local_date + 1)
    detect
    assert_equal "cleared", partials.find_by(delivery_order_id: order.id).status
  end

  test "managed dismissed and snoozed alerts respect cooldown and only reopen with a new cycle" do
    [ 30, 37, 44 ].each { |days| workflow_order(date: @company.local_date - days) }
    detect
    record = @company.commercial_opportunities.where(rule: "inactive").sole
    actions = WorkflowActions.new(users(:one))
    actions.opportunity_action(id: record.id, operation_id: SecureRandom.uuid, attributes: { version: record.lock_version, action: "dismissed", message: "Vacaciones confirmadas" })
    detect
    assert_equal "dismissed", record.reload.status
    assert_equal 1, record.generation
    travel 31.days do
      CommercialOpportunityDetector.new(@company).call
      assert_equal "open", record.reload.status
      assert_equal 2, record.generation
    end
    actions.opportunity_action(id: record.id, operation_id: SecureRandom.uuid, attributes: { version: record.lock_version, action: "snoozed", message: "Retomar la semana próxima", snoozed_until: 1.week.from_now.iso8601 })
    detect
    assert_equal "snoozed", record.reload.status
  end

  test "a late delivery is not treated as an overdue partial immediately after actual execution" do
    order = workflow_order(date: @company.local_date - 10)
    workflow_finish(workflow_plan([ order ]).visits.first, quantities: [ 4 ])
    detect
    assert_not @company.commercial_opportunities.exists?(rule: "unfollowed_partial")
    travel 3.days do
      detect
      assert @company.commercial_opportunities.exists?(rule: "unfollowed_partial", delivery_order: order)
    end
  end

  test "automatic commercial tasks are opt in idempotent and never assigned to drivers" do
    [ 30, 37, 44 ].each { |days| workflow_order(date: @company.local_date - days) }
    detect
    assert_equal 0, @company.workflow_tasks.count
    @settings.update!(automatic_rules: [ "inactive" ], auto_assignee: users(:supervisor))
    detect
    task = @company.workflow_tasks.sole
    assert_equal "commercial", task.category
    assert_equal users(:supervisor), task.assignee
    detect
    assert_equal 1, @company.workflow_tasks.count
    assert_empty DriverInbox.new(users(:driver)).tasks
    opportunity = task.commercial_opportunity.reload
    actions = WorkflowActions.new(users(:one))
    actions.opportunity_action(id: opportunity.id, operation_id: SecureRandom.uuid, attributes: { version: opportunity.lock_version, action: "managed", message: "Seguimiento en curso" })
    travel 31.days do
      detect
      assert_equal "open", opportunity.reload.status
      assert_equal 1, @company.workflow_tasks.count
      actions.update_task(id: task.id, operation_id: SecureRandom.uuid, attributes: { version: task.lock_version, action: "complete", result: "Se revisó la frecuencia de pedidos" })
      detect
      assert_equal 1, @company.workflow_tasks.count
    end
    assert_not @settings.update(auto_assignee: users(:driver))
  end
end
