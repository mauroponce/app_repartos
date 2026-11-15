class CreateOperationsCenter < ActiveRecord::Migration[8.1]
  def change
    create_table :driver_locations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false, index: { unique: true }
      t.decimal :latitude, precision: 10, scale: 7, null: false
      t.decimal :longitude, precision: 10, scale: 7, null: false
      t.decimal :accuracy, precision: 10, scale: 2, null: false
      t.datetime :captured_at, null: false
      t.boolean :sharing, null: false, default: true
      t.jsonb :eta_data, null: false, default: {}
      t.timestamps
    end
    add_foreign_key :driver_locations, :users, column: [ :company_id, :user_id ], primary_key: [ :company_id, :id ]
    add_check_constraint :driver_locations, "latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180 AND accuracy >= 0 AND accuracy < 100000000", name: "driver_location_coordinates"
    create_table :delivery_dispatch_changes do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false
      t.references :delivery_order, null: false
      t.jsonb :before_data, null: false
      t.jsonb :after_data, null: false
      t.string :reason, null: false
      t.timestamps
    end
    add_foreign_key :delivery_dispatch_changes, :users, column: [ :company_id, :user_id ], primary_key: [ :company_id, :id ]
    add_foreign_key :delivery_dispatch_changes, :delivery_orders, column: [ :company_id, :delivery_order_id ], primary_key: [ :company_id, :id ]
  end
end
