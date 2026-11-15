class PreserveAuditOfRemovedPendingVisits < ActiveRecord::Migration[8.1]
  def change
    # Pending stops may disappear during dispatch. Keep their identifier just
    # like offline sync receipts, rather than deleting the history with them.
    remove_foreign_key :delivery_status_events, :visits, column: [ :company_id, :visit_id ], primary_key: [ :company_id, :id ], name: "status_events_visit_tenant"
    add_column :delivery_status_events, :context, :jsonb, null: false, default: {}
  end
end
