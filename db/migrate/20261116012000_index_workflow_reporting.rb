class IndexWorkflowReporting < ActiveRecord::Migration[8.1]
  def change
    add_index :incidents, "company_id, COALESCE(occurred_at, created_at)", name: "incidents_reporting_time"
    add_index :workflow_events, [ :company_id, :id ], name: "workflow_events_company_revision"
  end
end
