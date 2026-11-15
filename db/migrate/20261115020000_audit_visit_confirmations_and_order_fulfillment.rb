class AuditVisitConfirmationsAndOrderFulfillment < ActiveRecord::Migration[8.1]
  def up
    add_reference :visits, :confirmed_by, index: false
    add_column :visits, :confirmed_at, :datetime
    add_index :visits, [ :company_id, :confirmed_by_id, :confirmed_at ], name: "visits_confirmation_history"
    add_foreign_key :visits, :users, column: [ :company_id, :confirmed_by_id ], primary_key: [ :company_id, :id ], name: "visits_confirmer_tenant"
    add_check_constraint :visits, "(confirmed_by_id IS NULL AND confirmed_at IS NULL) OR (confirmed_by_id IS NOT NULL AND confirmed_at IS NOT NULL AND status <> 'pending')", name: "visits_confirmation_pair"

    add_reference :delivery_orders, :rescheduled_from, index: { unique: true }
    add_index :delivery_orders, [ :company_id, :customer_id, :id ], unique: true, name: "orders_tenant_customer_id"
    add_foreign_key :delivery_orders, :delivery_orders, column: [ :company_id, :customer_id, :rescheduled_from_id ], primary_key: [ :company_id, :customer_id, :id ], name: "orders_reschedule_customer_tenant"
    add_check_constraint :delivery_orders, "rescheduled_from_id IS NULL OR rescheduled_from_id <> id", name: "orders_no_self_reschedule"
    remove_check_constraint :delivery_orders, name: "orders_valid_status"
    add_check_constraint :delivery_orders, "status IN ('pending','completed','needs_attention','cancelled')", name: "orders_valid_status"

    # Only reclassify fulfillment. Never infer an author/time or rewrite the
    # original visit, timestamps, snapshots, or quantities (including NULL).
    execute <<~SQL
      UPDATE delivery_orders AS orders
      SET status = CASE WHEN visits.status = 'completed'
        AND EXISTS (SELECT 1 FROM delivery_order_items oi WHERE oi.delivery_order_id = orders.id)
        AND NOT EXISTS (
          SELECT 1 FROM delivery_order_items oi
          LEFT JOIN delivery_items di ON di.delivery_order_item_id = oi.id AND di.visit_id = visits.id
          WHERE oi.delivery_order_id = orders.id
            AND (di.delivered_quantity IS NULL OR di.delivered_quantity < oi.quantity)
        ) THEN 'completed' ELSE 'needs_attention' END
      FROM visits
      WHERE orders.visit_id = visits.id AND visits.status <> 'pending' AND orders.status <> 'cancelled'
    SQL
    execute <<~SQL
      UPDATE delivery_orders AS orders SET status = 'needs_attention'
      WHERE orders.status = 'completed'
        AND NOT EXISTS (SELECT 1 FROM visits WHERE visits.id = orders.visit_id AND visits.status <> 'pending')
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "El cumplimiento y la autoría históricos no deben descartarse"
  end
end
