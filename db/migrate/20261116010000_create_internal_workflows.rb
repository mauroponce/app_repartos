class CreateInternalWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :incidents do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :reporter_id
      t.bigint :driver_id
      t.bigint :assigned_to_id
      t.bigint :delivery_run_id
      t.bigint :visit_id
      t.bigint :customer_id
      t.string :source_key, null: false
      t.string :source, null: false, default: "manual"
      t.string :kind, null: false
      t.string :priority, null: false, default: "normal"
      t.string :status, null: false, default: "needs_decision"
      t.text :description, null: false
      t.datetime :occurred_at
      t.datetime :due_at
      t.datetime :resolved_at
      t.text :resolution
      t.jsonb :context, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :commercial_opportunities do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :customer_id
      t.bigint :product_id
      t.bigint :delivery_order_id
      t.string :rule, null: false
      t.string :stable_key, null: false
      t.string :title, null: false
      t.jsonb :evidence, null: false, default: {}
      t.string :fingerprint, null: false
      t.string :acknowledged_fingerprint
      t.string :status, null: false, default: "open"
      t.integer :generation, null: false, default: 1
      t.datetime :detected_at, null: false
      t.datetime :last_evaluated_at, null: false
      t.datetime :state_changed_at, null: false
      t.datetime :snoozed_until
      t.text :resolution
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :workflow_tasks do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :creator_id
      t.bigint :assignee_id
      t.bigint :customer_id
      t.bigint :visit_id
      t.bigint :delivery_run_id
      t.bigint :delivery_order_id
      t.bigint :incident_id
      t.bigint :commercial_opportunity_id
      t.string :source_key, null: false
      t.string :title, null: false
      t.text :description
      t.string :category, null: false
      t.string :priority, null: false, default: "normal"
      t.string :status, null: false, default: "pending"
      t.datetime :due_at
      t.datetime :closed_at
      t.text :result
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :workflow_events do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :user_id
      t.bigint :incident_id
      t.bigint :workflow_task_id
      t.bigint :commercial_opportunity_id
      t.string :action, null: false
      t.text :message
      t.jsonb :changeset, null: false, default: {}
      t.datetime :created_at, null: false
    end
    create_table :internal_notices do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.bigint :sender_id
      t.bigint :incident_id
      t.bigint :workflow_task_id
      t.string :source_key, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.datetime :read_at
      t.datetime :acknowledged_at
      t.datetime :created_at, null: false
    end
    create_table :workflow_commands do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.uuid :operation_id, null: false
      t.string :payload_digest, null: false
      t.jsonb :result, null: false, default: {}
      t.datetime :created_at, null: false
    end
    create_table :incident_photos do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :incident_id, null: false
      t.bigint :user_id, null: false
      t.uuid :file_uuid, null: false
      t.string :sha256, null: false
      t.datetime :purged_at
      t.datetime :created_at, null: false
    end
    create_table :commercial_rule_settings do |t|
      t.references :company, null: false, foreign_key: true, index: { unique: true }
      t.integer :inactivity_min_days, null: false, default: 14
      t.decimal :inactivity_multiplier, precision: 4, scale: 1, null: false, default: 2.5
      t.integer :comparison_days, null: false, default: 30
      t.integer :decline_min_orders, null: false, default: 3
      t.integer :decline_percent, null: false, default: 40
      t.integer :shortage_min_orders, null: false, default: 3
      t.integer :failure_min_orders, null: false, default: 3
      t.integer :partial_grace_days, null: false, default: 2
      t.integer :cooldown_days, null: false, default: 30
      t.string :automatic_rules, array: true, null: false, default: []
      t.bigint :auto_assignee_id
      t.timestamps
    end
    add_column :companies, :opportunities_changed_at, :datetime
    add_column :companies, :opportunities_evaluated_at, :datetime
    add_column :companies, :opportunities_job_enqueued_at, :datetime

    add_index :incidents, [ :company_id, :source_key ], unique: true
    add_index :incidents, [ :company_id, :status, :created_at ]
    add_index :incidents, [ :company_id, :driver_id, :occurred_at ]
    add_index :incidents, [ :company_id, :assigned_to_id, :due_at ]
    add_index :workflow_tasks, [ :company_id, :source_key ], unique: true
    add_index :workflow_tasks, [ :company_id, :assignee_id, :status, :due_at ], name: "tasks_inbox"
    add_index :workflow_tasks, [ :company_id, :category, :status ]
    add_index :commercial_opportunities, [ :company_id, :stable_key ], unique: true, name: "opportunities_stable_key"
    add_index :commercial_opportunities, [ :company_id, :status, :detected_at ], name: "opportunities_inbox"
    add_index :workflow_commands, [ :company_id, :operation_id ], unique: true
    add_index :internal_notices, [ :company_id, :user_id, :source_key ], unique: true, name: "notices_deduplication"
    add_index :internal_notices, [ :company_id, :user_id, :read_at, :id ], name: "notices_inbox"
    add_index :incident_photos, [ :company_id, :file_uuid ], unique: true
    add_check_constraint :incidents, "status IN ('open','needs_decision','follow_up','resolved','dismissed') AND priority IN ('low','normal','high','urgent') AND kind IN ('closed','absent','rejected','shortage','damaged','address','vehicle','other') AND source IN ('manual','automatic')", name: "incidents_codes"
    add_check_constraint :incidents, "(status IN ('resolved','dismissed') AND resolved_at IS NOT NULL AND length(btrim(resolution)) > 0) OR (status NOT IN ('resolved','dismissed') AND resolved_at IS NULL)", name: "incident_resolution"
    add_check_constraint :workflow_tasks, "category IN ('operational','commercial','administrative') AND priority IN ('low','normal','high','urgent') AND status IN ('pending','in_progress','completed','cancelled')", name: "tasks_codes"
    add_check_constraint :workflow_tasks, "(status IN ('completed','cancelled') AND closed_at IS NOT NULL AND result IS NOT NULL AND length(btrim(result)) > 0) OR (status IN ('pending','in_progress') AND closed_at IS NULL)", name: "tasks_closure"
    add_check_constraint :commercial_opportunities, "status IN ('open','managed','snoozed','dismissed','cleared') AND rule IN ('inactive','decline','shortage','repeated_failure','unfollowed_partial') AND generation > 0", name: "opportunities_codes"
    add_check_constraint :workflow_events, "num_nonnulls(incident_id, workflow_task_id, commercial_opportunity_id) = 1", name: "workflow_event_subject"
    # Visit IDs are historical references: planners may remove empty pending
    # stops. Context snapshots survive that removal, like status events do.
    links = {
      incidents: { reporter: :users, driver: :users, assigned_to: :users, delivery_run: :delivery_runs, customer: :customers },
      workflow_tasks: { creator: :users, assignee: :users, customer: :customers, delivery_run: :delivery_runs, delivery_order: :delivery_orders, incident: :incidents, commercial_opportunity: :commercial_opportunities },
      commercial_opportunities: { customer: :customers, product: :products, delivery_order: :delivery_orders },
      workflow_events: { user: :users, incident: :incidents, workflow_task: :workflow_tasks, commercial_opportunity: :commercial_opportunities },
      internal_notices: { user: :users, sender: :users, incident: :incidents, workflow_task: :workflow_tasks },
      workflow_commands: { user: :users }, incident_photos: { user: :users, incident: :incidents },
      commercial_rule_settings: { auto_assignee: :users }
    }
    [ :incidents, :workflow_tasks, :commercial_opportunities ].each { |table| add_index table, [ :company_id, :id ], unique: true }
    links.each do |table, associations|
      associations.each do |association, target|
        add_foreign_key table, target, column: [ :company_id, :"#{association}_id" ], primary_key: [ :company_id, :id ], name: "#{table}_#{association}_tenant"
        add_index table, :"#{association}_id" unless index_exists?(table, :"#{association}_id")
      end
    end
    add_index :incidents, :visit_id
    add_index :workflow_tasks, :visit_id
    add_index :delivery_orders, [ :company_id, :scheduled_date, :customer_id ], name: "orders_reporting_date"
    add_index :delivery_order_items, [ :company_id, :product_id, :delivery_order_id ], name: "order_items_reporting_product"
  end
end
