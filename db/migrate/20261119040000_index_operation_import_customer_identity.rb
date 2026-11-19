class IndexOperationImportCustomerIdentity < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE INDEX operation_rows_customer_identity
      ON operation_import_rows (operation_import_id, (data->>'customer_key'), (data->>'address_identity_key'))
    SQL
  end

  def down
    execute "DROP INDEX operation_rows_customer_identity"
  end
end
