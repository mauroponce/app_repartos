class CreateDeliveryManagement < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :time_zone, :string, null: false, default: "America/Argentina/Buenos_Aires"
    add_index :customers, [ :company_id, :id ], unique: true
    add_index :users, [ :company_id, :id ], unique: true

    create_table :products do |t|
      t.references :company, null: false, foreign_key: true
      t.string :sku
      t.string :name, null: false
      t.string :unit, null: false
      t.decimal :package_content_quantity, precision: 12, scale: 3
      t.string :package_content_unit
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :products, [ :company_id, :sku ], unique: true, where: "sku IS NOT NULL"
    add_index :products, [ :company_id, :active, :name ]
    add_index :products, [ :company_id, :id ], unique: true
    add_check_constraint :products, "sku IS NULL OR btrim(sku) <> ''", name: "products_nonblank_sku"
    add_check_constraint :products, "btrim(name) <> ''", name: "products_nonblank_name"
    add_check_constraint :products, "unit IN (#{units})", name: "products_valid_unit"
    add_check_constraint :products, "(package_content_quantity IS NULL AND package_content_unit IS NULL) OR (package_content_quantity > 0 AND package_content_unit IS NOT NULL AND package_content_unit IN (#{units}))", name: "products_valid_package"
    add_check_constraint :products, "package_content_unit IS NULL OR package_content_unit NOT IN ('unit','pack','bag','box') OR package_content_quantity = trunc(package_content_quantity)", name: "products_integer_package"

    create_table :delivery_schedules do |t|
      t.references :company, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.integer :weekday, null: false
      t.time :preferred_time
      t.time :window_start
      t.time :window_end
      t.date :starts_on, null: false
      t.date :ends_on
      t.boolean :active, default: true, null: false
      t.text :notes
      t.timestamps
    end
    add_index :delivery_schedules, [ :company_id, :active, :weekday ]
    add_index :delivery_schedules, [ :company_id, :id ], unique: true
    add_index :delivery_schedules, [ :company_id, :customer_id, :id ], unique: true, name: "index_schedules_tenant_customer_id"
    tenant_foreign_key :delivery_schedules, :customers, :customer_id
    add_check_constraint :delivery_schedules, "weekday BETWEEN 1 AND 7", name: "schedules_valid_weekday"
    add_check_constraint :delivery_schedules, "ends_on IS NULL OR ends_on >= starts_on", name: "schedules_valid_dates"
    add_check_constraint :delivery_schedules, "(window_start IS NULL AND window_end IS NULL) OR (preferred_time IS NULL AND window_start IS NOT NULL AND window_end IS NOT NULL AND window_end > window_start)", name: "schedules_valid_times"

    create_table :delivery_schedule_items do |t|
      t.references :company, null: false, foreign_key: true
      t.references :delivery_schedule, null: false, foreign_key: true
      t.references :product, foreign_key: true
      t.string :description, null: false
      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.string :unit, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    tenant_foreign_key :delivery_schedule_items, :delivery_schedules, :delivery_schedule_id
    tenant_foreign_key :delivery_schedule_items, :products, :product_id
    merchandise_constraints :delivery_schedule_items, :quantity

    create_table :delivery_runs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :driver, foreign_key: { to_table: :users }
      t.date :scheduled_date, null: false
      t.string :name, null: false
      t.string :status, null: false, default: "draft"
      # NULL permits independent manual runs; generated runs use a date key.
      t.string :generation_key
      t.timestamps
    end
    add_index :delivery_runs, [ :company_id, :scheduled_date ]
    add_index :delivery_runs, [ :company_id, :id ], unique: true
    add_index :delivery_runs, [ :company_id, :generation_key ], unique: true, where: "generation_key IS NOT NULL"
    tenant_foreign_key :delivery_runs, :users, :driver_id
    add_check_constraint :delivery_runs, "status IN ('draft','assigned','in_progress','completed','cancelled')", name: "runs_valid_status"

    create_table :visits do |t|
      t.references :company, null: false, foreign_key: true
      t.references :delivery_run, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.references :delivery_schedule, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.string :customer_name, null: false
      t.string :customer_address, null: false
      t.text :notes
      t.datetime :completed_at
      t.timestamps
    end
    add_index :visits, [ :company_id, :id ], unique: true
    add_index :visits, [ :delivery_run_id, :delivery_schedule_id ], unique: true, where: "delivery_schedule_id IS NOT NULL"
    add_index :visits, [ :delivery_run_id, :position ]
    tenant_foreign_key :visits, :delivery_runs, :delivery_run_id
    tenant_foreign_key :visits, :customers, :customer_id
    add_foreign_key :visits, :delivery_schedules, column: [ :company_id, :customer_id, :delivery_schedule_id ], primary_key: [ :company_id, :customer_id, :id ], name: "fk_visits_schedule_customer_tenant"
    add_check_constraint :visits, "status IN ('pending','completed','not_attended','closed','rescheduled')", name: "visits_valid_status"

    create_table :delivery_items do |t|
      t.references :company, null: false, foreign_key: true
      t.references :visit, null: false, foreign_key: true
      t.references :product, foreign_key: true
      t.string :description, null: false
      t.string :unit, null: false
      t.decimal :planned_quantity, precision: 12, scale: 3, null: false
      t.decimal :delivered_quantity, precision: 12, scale: 3
      t.text :notes
      t.timestamps
    end
    tenant_foreign_key :delivery_items, :visits, :visit_id
    tenant_foreign_key :delivery_items, :products, :product_id
    merchandise_constraints :delivery_items, :planned_quantity
    add_check_constraint :delivery_items, "delivered_quantity IS NULL OR delivered_quantity >= 0", name: "items_nonnegative_delivered"
    add_check_constraint :delivery_items, "delivered_quantity IS NULL OR unit NOT IN ('unit','pack','bag','box') OR delivered_quantity = trunc(delivered_quantity)", name: "items_integer_delivered"

    create_table :product_imports do |t|
      t.references :company, null: false, foreign_key: true
      t.jsonb :headers, null: false, default: []
      t.jsonb :rows, null: false, default: []
      t.jsonb :mapping, null: false, default: {}
      t.datetime :confirmed_at
      t.timestamps
    end
  end

  private

  # Migration constants deliberately do not depend on future application code.
  def units
    "'unit','pack','bag','box','kg','g','l'"
  end

  def tenant_foreign_key(from, to, column)
    add_foreign_key from, to, column: [ :company_id, column ], primary_key: [ :company_id, :id ], name: "fk_#{from}_#{column}_tenant"
  end

  def merchandise_constraints(table, quantity)
    add_check_constraint table, "btrim(description) <> '' AND unit IN (#{units}) AND #{quantity} > 0", name: "#{table}_valid_merchandise"
    add_check_constraint table, "unit NOT IN ('unit','pack','bag','box') OR #{quantity} = trunc(#{quantity})", name: "#{table}_integer_quantity"
  end
end
