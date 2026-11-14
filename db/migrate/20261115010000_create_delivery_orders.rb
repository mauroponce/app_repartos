class CreateDeliveryOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :delivery_orders do |t|
      t.references :company, null: false, foreign_key: true
      t.references :customer, null: false
      t.references :delivery_schedule
      t.references :visit
      t.date :scheduled_date, null: false
      t.time :preferred_time
      t.time :window_start
      t.time :window_end
      t.string :customer_name, null: false
      t.string :customer_address, null: false
      t.string :status, null: false, default: "pending"
      t.text :notes
      t.timestamps
    end
    add_index :delivery_orders, [ :company_id, :id ], unique: true
    add_index :delivery_orders, [ :company_id, :scheduled_date, :status ]
    add_index :delivery_orders, [ :company_id, :delivery_schedule_id, :scheduled_date ], unique: true, where: "delivery_schedule_id IS NOT NULL", name: "orders_unique_schedule_date"
    tenant_key :delivery_orders, :customers, :customer_id
    add_foreign_key :delivery_orders, :delivery_schedules, column: [ :company_id, :customer_id, :delivery_schedule_id ], primary_key: [ :company_id, :customer_id, :id ], name: "orders_schedule_customer_tenant"
    add_index :visits, [ :company_id, :customer_id, :id ], unique: true, name: "visits_tenant_customer_id"
    add_foreign_key :delivery_orders, :visits, column: [ :company_id, :customer_id, :visit_id ], primary_key: [ :company_id, :customer_id, :id ], name: "orders_visit_customer_tenant"
    add_check_constraint :delivery_orders, "status IN ('pending','completed','cancelled')", name: "orders_valid_status"
    add_check_constraint :delivery_orders, "btrim(customer_name) <> '' AND btrim(customer_address) <> ''", name: "orders_customer_snapshot"
    add_check_constraint :delivery_orders, "(window_start IS NULL AND window_end IS NULL) OR (preferred_time IS NULL AND window_start IS NOT NULL AND window_end IS NOT NULL AND window_end > window_start)", name: "orders_valid_times"

    create_table :delivery_order_items do |t|
      t.references :company, null: false, foreign_key: true
      t.references :delivery_order, null: false
      t.references :product
      t.string :description, null: false
      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.string :unit, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :delivery_order_items, [ :company_id, :id ], unique: true
    tenant_key :delivery_order_items, :delivery_orders, :delivery_order_id
    tenant_key :delivery_order_items, :products, :product_id
    add_check_constraint :delivery_order_items, "btrim(description) <> '' AND unit IN ('unit','pack','bag','box','kg','g','l') AND quantity > 0 AND quantity < 1000000000", name: "order_items_valid_merchandise"
    add_check_constraint :delivery_order_items, "unit NOT IN ('unit','pack','bag','box') OR quantity = trunc(quantity)", name: "order_items_integer_quantity"
    add_check_constraint :delivery_order_items, "position >= 0", name: "order_items_valid_position"
    add_reference :delivery_items, :delivery_order_item, index: { unique: true }
    tenant_key :delivery_items, :delivery_order_items, :delivery_order_item_id
  end

  private

  def tenant_key(from, to, column)
    add_foreign_key from, to, column: [ :company_id, column ], primary_key: [ :company_id, :id ], name: "fk_#{from}_#{column}_tenant"
  end
end
