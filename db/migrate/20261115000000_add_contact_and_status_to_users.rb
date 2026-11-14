class AddContactAndStatusToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :phone, :string
    add_column :users, :status, :string, default: "active", null: false
    add_index :users, [ :company_id, :role, :status ]
    add_check_constraint :users, "status IN ('active', 'inactive')", name: "users_valid_status"
  end
end
