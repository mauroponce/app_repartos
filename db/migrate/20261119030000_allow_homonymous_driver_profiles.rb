class AllowHomonymousDriverProfiles < ActiveRecord::Migration[8.1]
  def change
    remove_index :driver_profiles, column: [ :company_id, :name_key ]
    add_index :driver_profiles, [ :company_id, :name_key ]
  end
end
