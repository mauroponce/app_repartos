require "test_helper"
require_relative "../../db/migrate/20261115020000_audit_visit_confirmations_and_order_fulfillment"

class DeliveryFulfillmentMigrationTest < ActiveSupport::TestCase
  def after_teardown
    super
    # The rolled-back DDL restores column order. Statements prepared against
    # the temporary schema must not leak into the next test in this process.
    ActiveRecord::Base.connection.clear_cache!
  end

  test "migration reclassifies old orders while preserving execution and unknown authorship" do
    company = companies(:one)
    cases = [
      [ "completed", 20, "completed", "completed" ],
      [ "completed", 18, "completed", "needs_attention" ],
      [ "completed", 0, "completed", "needs_attention" ],
      [ "completed", nil, "completed", "needs_attention" ],
      [ "not_attended", nil, "pending", "needs_attention" ],
      [ "closed", 0, "pending", "needs_attention" ],
      [ "rescheduled", 0, "pending", "needs_attention" ],
      [ "pending", nil, "pending", "pending" ],
      [ "pending", nil, "completed", "needs_attention" ],
      [ "closed", 0, "cancelled", "cancelled" ]
    ]
    records = cases.map do |visit_status, delivered, old_order_status, expected|
      order = company.delivery_orders.create!(customer: customers(:one), scheduled_date: "2026-11-17",
        delivery_order_items_attributes: [ { description: "Histórico", quantity: 20, unit: "pack" } ])
      run = company.delivery_runs.new(name: "Legado", scheduled_date: order.scheduled_date, driver: users(:driver), status: :assigned)
      DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: [ order.id ])
      visit = order.reload.visit
      item = visit.delivery_items.first
      item.update_columns(delivered_quantity: delivered)
      visit.update_columns(status: visit_status, completed_at: visit_status == "completed" ? 3.days.ago : nil)
      order.update_columns(status: old_order_status)
      [ order, visit, item, expected, order.attributes.except("status"), visit.attributes, item.attributes ]
    end
    orphan = company.delivery_orders.create!(customer: customers(:one), scheduled_date: "2026-11-17",
      delivery_order_items_attributes: [ { description: "Sin visita", quantity: 2, unit: "box" } ])
    orphan.update_columns(status: "completed")

    # PostgreSQL DDL is transactional. Reconstruct the previous schema inside
    # this test's rollback transaction, then run the actual migration with data.
    connection = ActiveRecord::Base.connection
    connection.remove_foreign_key :visits, name: "visits_confirmer_tenant"
    connection.remove_check_constraint :visits, name: "visits_confirmation_pair"
    connection.remove_column :visits, :confirmed_by_id
    connection.remove_column :visits, :confirmed_at
    connection.remove_foreign_key :delivery_orders, name: "orders_reschedule_customer_tenant"
    connection.remove_check_constraint :delivery_orders, name: "orders_no_self_reschedule"
    connection.remove_column :delivery_orders, :rescheduled_from_id
    # This newer ledger also uses the index being reconstructed. The test's
    # rollback restores the foreign key along with the rest of today's schema.
    connection.remove_foreign_key :customer_notifications, name: "notifications_order_customer_tenant"
    connection.remove_foreign_key :workflow_tasks, name: "task_order_customer_tenant"
    connection.remove_index :delivery_orders, name: "orders_tenant_customer_id"
    connection.remove_check_constraint :delivery_orders, name: "orders_valid_status"
    connection.add_check_constraint :delivery_orders, "status IN ('pending','completed','cancelled')", name: "orders_valid_status"
    ActiveRecord::Migration.suppress_messages { AuditVisitConfirmationsAndOrderFulfillment.new.up }

    records.each do |order, visit, item, expected, order_snapshot, visit_snapshot, item_snapshot|
      assert_equal expected, order.reload.status
      assert_equal order_snapshot, order.attributes.except("status")
      assert_equal visit_snapshot, visit.reload.attributes
      assert_equal item_snapshot, item.reload.attributes
      assert_nil visit.confirmed_by_id
      assert_nil visit.confirmed_at
    end
    assert orphan.reload.needs_attention?
  end
end
