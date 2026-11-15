class AddSingleRouteOptimization < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :depot_latitude, :decimal, precision: 10, scale: 7
    add_column :companies, :depot_longitude, :decimal, precision: 10, scale: 7
    add_column :companies, :routing_departure, :string, default: "08:00", null: false
    add_column :companies, :routing_return_to_depot, :boolean, default: false, null: false
    add_column :companies, :routing_preferred_tolerance, :integer, default: 15, null: false
    add_column :companies, :routing_service_minutes, :integer, default: 5, null: false
    add_check_constraint :companies, "(depot_latitude IS NULL AND depot_longitude IS NULL) OR (depot_latitude IS NOT NULL AND depot_longitude IS NOT NULL AND depot_latitude BETWEEN -90 AND 90 AND depot_longitude BETWEEN -180 AND 180)", name: "company_depot_coordinates"
    add_check_constraint :companies, "routing_preferred_tolerance BETWEEN 0 AND 120 AND routing_service_minutes BETWEEN 0 AND 240 AND routing_departure ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' AND (NOT routing_return_to_depot OR depot_latitude IS NOT NULL)", name: "company_routing_settings"
    add_column :delivery_runs, :routing_origin, :string, default: "company", null: false
    add_column :delivery_runs, :routing_return_to_depot, :boolean
    add_check_constraint :delivery_runs, "routing_origin IN ('company','open')", name: "run_routing_origin"
    create_table :route_optimization_proposals do |t|
      t.references :company, null: false, foreign_key: true
      t.references :delivery_run, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :applied_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "queued"
      t.string :fingerprint, null: false
      t.string :request_key, null: false
      t.jsonb :settings, null: false, default: {}
      t.jsonb :result, null: false, default: {}
      t.text :error_message
      t.datetime :expires_at, null: false
      t.datetime :applied_at
      t.timestamps
    end
    add_index :route_optimization_proposals, [ :company_id, :delivery_run_id, :request_key ], unique: true, where: "status IN ('queued','processing','ready')", name: "unique_active_route_proposal"
    add_index :route_optimization_proposals, [ :company_id, :delivery_run_id, :created_at ], name: "route_proposals_history"
    add_check_constraint :route_optimization_proposals, "status IN ('queued','processing','ready','failed','applied','discarded','expired')", name: "route_proposal_status"
    %i[delivery_run requested_by applied_by].each do |name|
      target = name == :delivery_run ? :delivery_runs : :users
      add_foreign_key :route_optimization_proposals, target, column: [ "#{name}_id", :company_id ], primary_key: [ :id, :company_id ]
    end
  end
end
