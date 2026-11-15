class AddRouteOptimization < ActiveRecord::Migration[8.1]
  def change
    add_column :delivery_orders, :load_units, :integer, null: false, default: 1
    add_column :delivery_orders, :service_minutes, :integer, null: false, default: 10
    add_check_constraint :delivery_orders, "load_units BETWEEN 1 AND 1000000", name: "orders_load_units"
    add_check_constraint :delivery_orders, "service_minutes BETWEEN 0 AND 1440", name: "orders_service_minutes"

    add_column :delivery_runs, :optimization_key, :string
    add_column :delivery_runs, :optimization_data, :jsonb, null: false, default: {}
    add_index :delivery_runs, [ :company_id, :optimization_key, :driver_id ], unique: true, where: "optimization_key IS NOT NULL", name: "runs_unique_optimization_vehicle"
  end
end
