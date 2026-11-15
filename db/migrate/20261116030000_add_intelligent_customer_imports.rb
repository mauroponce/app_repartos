class AddIntelligentCustomerImports < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :location_verification, :string, null: false, default: "legacy"
    add_check_constraint :customers, "location_verification IN ('legacy','pending','provided','reliable','manual')", name: "customers_location_verification"
    add_reference :customer_imports, :initiated_by, foreign_key: { to_table: :users }
    add_column :customer_imports, :state, :string, null: false, default: "legacy"
    add_column :customer_imports, :generation, :integer, null: false, default: 0
    add_column :customer_imports, :sheet_names, :jsonb, null: false, default: []
    add_column :customer_imports, :sheet_index, :integer, null: false, default: 0
    add_column :customer_imports, :header_row, :integer, null: false, default: 1
    add_column :customer_imports, :geographic_context, :jsonb, null: false, default: {}
    add_column :customer_imports, :total_rows, :integer, null: false, default: 0
    add_column :customer_imports, :processed_rows, :integer, null: false, default: 0
    add_column :customer_imports, :last_error, :text
    add_column :customer_imports, :heartbeat_at, :datetime
    add_index :customer_imports, [ :state, :heartbeat_at ]
    add_index :customer_imports, [ :company_id, :id ], unique: true
    add_foreign_key :customer_imports, :users, column: [ :company_id, :initiated_by_id ], primary_key: [ :company_id, :id ], name: "customer_import_initiator_tenant"
    add_check_constraint :customer_imports, "state IN ('legacy','reading','mapping','preparing','processing','review','importing','completed','cancelled','failed')", name: "customer_import_state"
    add_check_constraint :customer_imports, "total_rows >= 0 AND processed_rows >= 0 AND processed_rows <= total_rows AND generation >= 0", name: "customer_import_progress"

    create_table :customer_import_rows do |t|
      t.references :company, null: false, foreign_key: true
      t.references :customer_import, null: false
      t.references :customer
      t.integer :number, null: false
      t.jsonb :original, null: false, default: []
      t.jsonb :data, null: false, default: {}
      t.jsonb :normalized, null: false, default: {}
      t.jsonb :candidates, null: false, default: []
      t.jsonb :issues, null: false, default: []
      t.jsonb :warnings, null: false, default: []
      t.jsonb :duplicates, null: false, default: []
      t.string :address_key
      t.string :duplicate_key
      t.string :precision, null: false, default: "unlocated"
      t.string :review_state, null: false, default: "pending"
      t.string :provider
      t.decimal :latitude, precision: 10, scale: 7
      t.decimal :longitude, precision: 11, scale: 7
      t.boolean :excluded, null: false, default: false
      t.boolean :manual_confirmation, null: false, default: false
      t.integer :attempts, null: false, default: 0
      t.datetime :processed_at
      t.timestamps
    end
    add_index :customer_import_rows, [ :customer_import_id, :number ], unique: true
    add_index :customer_import_rows, [ :customer_import_id, :processed_at, :id ], name: "customer_import_rows_pending"
    add_index :customer_import_rows, [ :customer_import_id, :precision, :id ], name: "customer_import_rows_precision"
    add_index :customer_import_rows, [ :customer_import_id, :duplicate_key ], name: "customer_import_rows_duplicates"
    add_index :customer_import_rows, "customer_import_id, (data->>'external_code')", name: "customer_import_rows_external_code"
    add_index :customer_import_rows, [ :customer_import_id, :address_key ], name: "customer_import_rows_addresses"
    add_index :customer_import_rows, :customer_id, unique: true, where: "customer_id IS NOT NULL", name: "customer_import_rows_created_customer"
    add_foreign_key :customer_import_rows, :customer_imports, column: [ :company_id, :customer_import_id ], primary_key: [ :company_id, :id ], name: "customer_import_row_tenant"
    add_foreign_key :customer_import_rows, :customers, column: [ :company_id, :customer_id ], primary_key: [ :company_id, :id ], name: "customer_import_row_customer_tenant"
    add_check_constraint :customer_import_rows, "precision IN ('reliable','approximate','ambiguous','unlocated') AND review_state IN ('pending','automatic','manual','unlocated')", name: "customer_import_row_states"
    add_check_constraint :customer_import_rows, "(latitude IS NULL AND longitude IS NULL) OR (latitude IS NOT NULL AND longitude IS NOT NULL AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)", name: "customer_import_row_coordinates"
    add_check_constraint :customer_import_rows, "NOT manual_confirmation OR (review_state = 'manual' AND latitude IS NOT NULL AND longitude IS NOT NULL)", name: "customer_import_row_manual"

    create_table :geocoding_cache_entries do |t|
      t.references :company, null: false, foreign_key: true
      t.string :key, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :geocoding_cache_entries, [ :company_id, :key ], unique: true
    add_index :geocoding_cache_entries, :expires_at
    create_table :geocoding_provider_states do |t|
      t.string :provider, null: false
      t.datetime :available_at
      t.date :quota_date
      t.integer :requests, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.bigint :tokens, null: false, default: 0
      t.timestamps
    end
    add_index :geocoding_provider_states, :provider, unique: true
  end
end
