class StrengthenWorkflowIntegrity < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :incidents, "status NOT IN ('resolved','dismissed') OR resolution IS NOT NULL", name: "incidents_resolution_present"
    add_check_constraint :internal_notices, "acknowledged_at IS NULL OR (read_at IS NOT NULL AND acknowledged_at >= read_at)", name: "notices_acknowledgement"
    add_check_constraint :commercial_opportunities, "status <> 'snoozed' OR snoozed_until IS NOT NULL", name: "opportunities_snoozed_until"
    add_check_constraint :commercial_rule_settings, "inactivity_min_days BETWEEN 1 AND 365 AND comparison_days BETWEEN 1 AND 365 AND partial_grace_days BETWEEN 1 AND 365 AND cooldown_days BETWEEN 1 AND 365 AND inactivity_multiplier BETWEEN 1 AND 10 AND decline_percent BETWEEN 1 AND 100 AND decline_min_orders BETWEEN 1 AND 1000 AND shortage_min_orders BETWEEN 1 AND 1000 AND failure_min_orders BETWEEN 1 AND 1000", name: "commercial_rule_thresholds"
    add_check_constraint :commercial_rule_settings, "automatic_rules <@ ARRAY['inactive','decline','shortage','repeated_failure','unfollowed_partial']::varchar[] AND (cardinality(automatic_rules) = 0 OR auto_assignee_id IS NOT NULL)", name: "commercial_automatic_rules"
    add_foreign_key :workflow_tasks, :delivery_orders, column: [ :company_id, :customer_id, :delivery_order_id ], primary_key: [ :company_id, :customer_id, :id ], name: "task_order_customer_tenant"
  end
end
