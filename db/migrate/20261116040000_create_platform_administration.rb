class CreatePlatformAdministration < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_admins do |t|
      t.string :name, null: false
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :platform_admins, :email_address, unique: true
    create_table :platform_sessions do |t|
      t.references :platform_admin, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_reference :companies, :primary_administrator, foreign_key: { to_table: :users }
  end
end
