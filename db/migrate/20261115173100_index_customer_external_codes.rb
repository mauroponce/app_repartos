class IndexCustomerExternalCodes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :customers, [ :company_id, :external_code ], unique: true, where: "external_code IS NOT NULL", algorithm: :concurrently
  end
end
