class BindConsentsToRecipient < ActiveRecord::Migration[8.1]
  def change
    add_column :communication_consents, :recipient, :string, null: false, default: ""
  end
end
