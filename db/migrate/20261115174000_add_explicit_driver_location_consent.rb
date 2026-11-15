class AddExplicitDriverLocationConsent < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :location_sharing_enabled, :boolean, null: false, default: false
    add_column :users, :location_consent_id, :uuid
    add_column :users, :location_consent_version, :bigint, null: false, default: 0
    add_column :users, :location_activated_at, :datetime
    add_column :users, :location_deactivated_at, :datetime
    add_check_constraint :users, "location_consent_version >= 0 AND (NOT location_sharing_enabled OR (location_consent_id IS NOT NULL AND location_activated_at IS NOT NULL))", name: "users_location_consent"
  end
end
