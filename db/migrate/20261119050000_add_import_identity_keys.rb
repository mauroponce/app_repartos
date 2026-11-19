class AddImportIdentityKeys < ActiveRecord::Migration[8.1]
  def up
    add_column :customers, :import_identity_key, :string
    add_index :customers, [ :company_id, :import_identity_key ]
    add_column :products, :name_key, :string
    add_index :products, [ :company_id, :name_key ]
    Customer.reset_column_information
    Product.reset_column_information
    Customer.find_each(batch_size: 500) do |customer|
      customer.update_columns(import_identity_key: [ customer.name, customer.address, customer.city ].map { |value| Geocoding::Address.fold(value) }.join("|"))
    end
    Product.find_each(batch_size: 500) do |product|
      product.update_columns(name_key: Geocoding::Address.fold(product.name))
    end
  end

  def down
    remove_index :products, [ :company_id, :name_key ]
    remove_column :products, :name_key
    remove_index :customers, [ :company_id, :import_identity_key ]
    remove_column :customers, :import_identity_key
  end
end
