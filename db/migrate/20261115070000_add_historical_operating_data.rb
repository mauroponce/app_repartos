class AddHistoricalOperatingData < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :currency, :string, null: false, default: "ARS"
    add_check_constraint :companies, "currency IN ('ARS','USD','EUR')", name: "companies_currency"
    add_column :products, :unit_price, :decimal, precision: 16, scale: 4
    add_column :products, :unit_cost, :decimal, precision: 16, scale: 4
    [ :products, :delivery_order_items, :delivery_items ].each do |table|
      unless table == :products
        add_column table, :unit_price, :decimal, precision: 16, scale: 4
        add_column table, :unit_cost, :decimal, precision: 16, scale: 4
        add_column table, :currency, :string
        add_column table, :commercial_captured_at, :datetime
        add_column table, :commercial_source, :string
        add_check_constraint table, "currency IS NULL OR currency IN ('ARS','USD','EUR')", name: "#{table}_currency"
        add_check_constraint table, "(unit_price IS NULL AND unit_cost IS NULL) OR (currency IS NOT NULL AND commercial_captured_at IS NOT NULL AND commercial_source IN ('catalog','manual','order','legacy'))", name: "#{table}_commercial_snapshot"
      end
      [ :unit_price, :unit_cost ].each do |column|
        add_check_constraint table, "#{column} IS NULL OR (#{column} >= 0 AND #{column} < 1000000000000)", name: "#{table}_#{column}_range"
      end
    end
    add_column :delivery_runs, :currency, :string
    add_column :delivery_runs, :vehicle_label, :string
    add_column :delivery_runs, :costs_closed_at, :datetime
    add_reference :delivery_runs, :costs_closed_by, foreign_key: { to_table: :users }
    add_check_constraint :delivery_runs, "(costs_closed_at IS NULL AND costs_closed_by_id IS NULL) OR (costs_closed_at IS NOT NULL AND costs_closed_by_id IS NOT NULL)", name: "runs_cost_closure"
    add_foreign_key :delivery_runs, :users, column: [ :company_id, :costs_closed_by_id ], primary_key: [ :company_id, :id ], name: "runs_cost_closer_tenant"
    [ :arrived_at, :unloading_started_at, :unloading_finished_at ].each { |column| add_column :visits, column, :datetime }
    add_check_constraint :visits, "(unloading_started_at IS NULL OR (arrived_at IS NOT NULL AND unloading_started_at >= arrived_at)) AND (unloading_finished_at IS NULL OR (unloading_started_at IS NOT NULL AND unloading_finished_at >= unloading_started_at))", name: "visits_timing_order"

    create_table :delivery_status_events do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :delivery_run_id
      t.bigint :visit_id
      t.bigint :delivery_order_id
      t.bigint :user_id
      t.string :from_status
      t.string :to_status, null: false
      t.string :source, null: false
      t.uuid :operation_id
      t.datetime :occurred_at
      t.datetime :client_occurred_at
      t.datetime :created_at, null: false
    end
    add_check_constraint :delivery_status_events, "num_nonnulls(delivery_run_id, visit_id, delivery_order_id) = 1", name: "status_events_one_subject"
    add_check_constraint :delivery_status_events, "(source = 'baseline' AND occurred_at IS NULL) OR (source IN ('system','manager','driver','offline') AND occurred_at IS NOT NULL)", name: "status_events_source"
    [ :delivery_run, :visit, :delivery_order, :user ].each do |association|
      add_foreign_key :delivery_status_events, association.to_s.pluralize.to_sym, column: [ :company_id, :"#{association}_id" ], primary_key: [ :company_id, :id ], name: "status_events_#{association}_tenant"
    end
    [ :delivery_run_id, :visit_id, :delivery_order_id ].each do |column|
      add_index :delivery_status_events, [ :company_id, column, :id ], name: "status_events_#{column}"
    end
    reversible do |dir|
      dir.up do
        # A baseline is an observation of current state, not an invented date
        # of the last historical transition. Old monetary values stay NULL.
        { delivery_runs: :delivery_run_id, visits: :visit_id, delivery_orders: :delivery_order_id }.each do |table, column|
          execute "INSERT INTO delivery_status_events (company_id, #{column}, to_status, source, created_at) SELECT company_id, id, status, 'baseline', CURRENT_TIMESTAMP FROM #{table}"
        end
      end
    end
  end
end
