class CreateDriverSyncOperations < ActiveRecord::Migration[8.1]
  def change
    add_column :delivery_runs, :assignment_version, :integer, null: false, default: 0
    add_check_constraint :delivery_runs, "assignment_version >= 0", name: "runs_assignment_version"
    create_table :driver_sync_operations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false
      # May be missing/deleted; keep the submitted identifier and payload for review.
      t.bigint :visit_id, null: false
      t.uuid :operation_id, null: false
      t.jsonb :payload, null: false
      t.string :payload_digest, null: false
      t.string :status, null: false
      t.jsonb :result, null: false, default: {}
      t.datetime :recorded_at
      t.timestamps
    end
    add_index :driver_sync_operations, [ :company_id, :user_id, :operation_id ], unique: true, name: "driver_sync_unique_operation"
    add_index :driver_sync_operations, [ :company_id, :status, :created_at ], name: "driver_sync_review_queue"
    add_foreign_key :driver_sync_operations, :users, column: [ :company_id, :user_id ], primary_key: [ :company_id, :id ], name: "driver_sync_user_tenant"
    add_check_constraint :driver_sync_operations, "status IN ('synced','conflict','invalid')", name: "driver_sync_valid_status"
  end
end
