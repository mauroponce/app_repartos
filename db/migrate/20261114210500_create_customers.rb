class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    create_table :customers do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false, limit: 90
      t.string :contact
      t.string :phone, null: false
      t.string :email
      t.string :address, null: false
      t.string :city, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :customers, [ :company_id, :name, :id ]
    add_index :customers, [ :company_id, :status ]
    add_check_constraint :customers, "status IN ('active', 'inactive')", name: "customers_valid_status"
  end
end
