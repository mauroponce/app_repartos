class CreateOperatingLedgers < ActiveRecord::Migration[8.1]
  def change
    create_table :delivery_run_costs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :delivery_run, null: false
      t.references :user, null: false
      t.uuid :operation_id, null: false
      t.string :category, null: false
      t.string :description, null: false
      t.string :vehicle_label
      t.string :currency, null: false
      t.decimal :amount, precision: 16, scale: 4, null: false
      t.boolean :estimated, null: false, default: false
      t.datetime :incurred_at, null: false
      t.bigint :reversal_of_id
      t.datetime :created_at, null: false
    end
    add_index :delivery_run_costs, [ :company_id, :id ], unique: true
    add_index :delivery_run_costs, [ :company_id, :operation_id ], unique: true
    add_index :delivery_run_costs, :reversal_of_id, unique: true
    add_check_constraint :delivery_run_costs, "amount > -1000000000000 AND amount < 1000000000000 AND ((reversal_of_id IS NULL AND amount >= 0) OR (reversal_of_id IS NOT NULL AND amount <= 0))", name: "run_costs_amount"
    add_check_constraint :delivery_run_costs, "category IN ('vehicle','fuel','toll','driver','other') AND currency IN ('ARS','USD','EUR')", name: "run_costs_codes"
    add_foreign_key :delivery_run_costs, :delivery_run_costs, column: [ :company_id, :reversal_of_id ], primary_key: [ :company_id, :id ], name: "run_costs_reversal_tenant"

    create_table :run_stock_movements do |t|
      t.references :company, null: false, foreign_key: true
      t.references :delivery_run, null: false
      t.bigint :user_id
      t.bigint :product_id
      t.bigint :delivery_item_id
      t.uuid :operation_id, null: false
      t.string :kind, null: false
      t.string :description, null: false
      t.string :unit, null: false
      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.string :reason
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :delivery_items, [ :company_id, :id ], unique: true
    add_index :run_stock_movements, [ :company_id, :operation_id ], unique: true
    add_index :run_stock_movements, :delivery_item_id, unique: true, where: "kind = 'delivery'"
    add_check_constraint :run_stock_movements, "kind IN ('load','delivery','return','waste','adjustment_in','adjustment_out') AND quantity > 0 AND quantity < 1000000000", name: "stock_movement_quantity"
    add_check_constraint :run_stock_movements, "unit IN ('unit','pack','bag','box','kg','g','l') AND (unit NOT IN ('unit','pack','bag','box') OR quantity = trunc(quantity))", name: "stock_movement_unit"
    add_check_constraint :run_stock_movements, "kind <> 'delivery' OR delivery_item_id IS NOT NULL", name: "stock_movement_delivery_source"
    [ :delivery_run_costs, :run_stock_movements ].each do |table|
      [ :delivery_run, :user ].each do |association|
        add_foreign_key table, association.to_s.pluralize.to_sym, column: [ :company_id, :"#{association}_id" ], primary_key: [ :company_id, :id ], name: "#{table}_#{association}_tenant"
      end
    end
    add_foreign_key :run_stock_movements, :products, column: [ :company_id, :product_id ], primary_key: [ :company_id, :id ], name: "stock_product_tenant"
    add_foreign_key :run_stock_movements, :delivery_items, column: [ :company_id, :delivery_item_id ], primary_key: [ :company_id, :id ], name: "stock_execution_tenant"
  end
end
