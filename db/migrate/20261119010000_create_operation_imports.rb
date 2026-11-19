class CreateOperationImports < ActiveRecord::Migration[8.1]
  def change
    create_table :driver_profiles do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :name, null: false
      t.string :name_key, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index [ :company_id, :name_key ], unique: true
      t.index [ :company_id, :id ], unique: true
      t.index [ :company_id, :user_id ], unique: true, where: "user_id IS NOT NULL"
    end
    add_foreign_key :driver_profiles, :users, column: [ :company_id, :user_id ], primary_key: [ :company_id, :id ], name: "driver_profiles_user_tenant"

    add_reference :delivery_schedules, :driver_profile, foreign_key: true
    add_column :delivery_schedules, :operation_kind, :string, null: false, default: "pedido_semanal"
    add_column :delivery_schedules, :visit_order, :integer
    add_column :delivery_schedules, :import_key, :string
    add_index :delivery_schedules, [ :company_id, :import_key ], unique: true, where: "import_key IS NOT NULL"
    add_foreign_key :delivery_schedules, :driver_profiles, column: [ :company_id, :driver_profile_id ], primary_key: [ :company_id, :id ], name: "schedules_driver_profile_tenant"
    add_check_constraint :delivery_schedules, "operation_kind IN ('visita_semanal', 'pedido_semanal')", name: "schedule_operation_kind"
    add_check_constraint :delivery_schedules, "visit_order IS NULL OR visit_order > 0", name: "schedule_visit_order"

    add_reference :delivery_orders, :driver_profile, foreign_key: true
    add_column :delivery_orders, :import_key, :string
    add_index :delivery_orders, [ :company_id, :import_key ], unique: true, where: "import_key IS NOT NULL"
    add_foreign_key :delivery_orders, :driver_profiles, column: [ :company_id, :driver_profile_id ], primary_key: [ :company_id, :id ], name: "orders_driver_profile_tenant"

    add_column :customers, :geocoding_precision, :string
    add_column :customers, :geocoding_checked_at, :datetime

    create_table :operation_imports do |t|
      t.references :company, null: false, foreign_key: true
      t.references :initiated_by, foreign_key: { to_table: :users }
      t.string :state, null: false, default: "reading"
      t.string :sha256, null: false
      t.integer :total_rows, null: false, default: 0
      t.integer :processed_rows, null: false, default: 0
      t.integer :imported_groups, null: false, default: 0
      t.text :last_error
      t.timestamps
      t.index [ :company_id, :sha256 ]
      t.index [ :company_id, :id ], unique: true
    end
    add_foreign_key :operation_imports, :users, column: [ :company_id, :initiated_by_id ], primary_key: [ :company_id, :id ], name: "operation_import_user_tenant"

    create_table :operation_import_groups do |t|
      t.references :company, null: false, foreign_key: true
      t.references :operation_import, null: false, foreign_key: true
      t.string :group_key, null: false
      t.string :state, null: false, default: "pending"
      t.jsonb :data, null: false, default: {}
      t.jsonb :issues, null: false, default: []
      t.jsonb :decisions, null: false, default: {}
      t.references :customer, foreign_key: true
      t.references :driver_profile, foreign_key: true
      t.integer :row_count, null: false, default: 0
      t.timestamps
      t.index [ :operation_import_id, :group_key ], unique: true, name: "operation_groups_unique_key"
      t.index [ :company_id, :state ]
      t.index [ :company_id, :id ], unique: true
    end
    add_foreign_key :operation_import_groups, :operation_imports, column: [ :company_id, :operation_import_id ], primary_key: [ :company_id, :id ], name: "operation_groups_import_tenant"
    add_foreign_key :operation_import_groups, :customers, column: [ :company_id, :customer_id ], primary_key: [ :company_id, :id ], name: "operation_groups_customer_tenant"
    add_foreign_key :operation_import_groups, :driver_profiles, column: [ :company_id, :driver_profile_id ], primary_key: [ :company_id, :id ], name: "operation_groups_driver_tenant"

    create_table :operation_import_rows do |t|
      t.references :company, null: false, foreign_key: true
      t.references :operation_import, null: false, foreign_key: true
      t.references :operation_import_group, foreign_key: true
      t.integer :number, null: false
      t.jsonb :original, null: false, default: {}
      t.jsonb :data, null: false, default: {}
      t.jsonb :issues, null: false, default: []
      t.timestamps
      t.index [ :operation_import_id, :number ], unique: true, name: "operation_rows_source_number"
      t.index [ :operation_import_group_id, :id ], name: "operation_rows_group"
    end
    add_foreign_key :operation_import_rows, :operation_imports, column: [ :company_id, :operation_import_id ], primary_key: [ :company_id, :id ], name: "operation_rows_import_tenant"
    add_foreign_key :operation_import_rows, :operation_import_groups, column: [ :company_id, :operation_import_group_id ], primary_key: [ :company_id, :id ], name: "operation_rows_group_tenant"
  end
end
