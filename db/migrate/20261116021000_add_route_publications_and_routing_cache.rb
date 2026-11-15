class AddRoutePublicationsAndRoutingCache < ActiveRecord::Migration[8.1]
  def change
    add_column :route_optimization_proposals, :auto_publish, :boolean, default: false, null: false
    add_index :route_optimization_proposals, [ :id, :company_id ], unique: true
    create_table :route_publications do |t|
      t.references :company, null: false, foreign_key: true
      t.references :delivery_run, null: false, foreign_key: true, index: { unique: true }
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :proposal, foreign_key: { to_table: :route_optimization_proposals }
      t.string :state, null: false, default: "pending"
      t.string :input_key
      t.jsonb :settings, null: false, default: {}
      t.text :error_message
      t.timestamps
    end
    add_check_constraint :route_publications, "state IN ('pending','ready','failed','manual')", name: "route_publication_state"
    { delivery_run: :delivery_runs, requested_by: :users, proposal: :route_optimization_proposals }.each do |name, table|
      add_foreign_key :route_publications, table, column: [ "#{name}_id", :company_id ], primary_key: [ :id, :company_id ]
    end
    add_index :route_publications, [ :company_id, :state, :updated_at ], name: "pending_route_publications"

    create_table :routing_cache_entries do |t|
      t.references :company, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :cache_key, null: false
      t.jsonb :data, null: false
      t.datetime :last_used_at, null: false
      t.timestamps
    end
    add_index :routing_cache_entries, [ :company_id, :kind, :cache_key ], unique: true, name: "unique_routing_cache_entry"
    add_index :routing_cache_entries, :last_used_at
    add_check_constraint :routing_cache_entries, "kind IN ('matrix','solution','geometry')", name: "routing_cache_kind"
  end
end
