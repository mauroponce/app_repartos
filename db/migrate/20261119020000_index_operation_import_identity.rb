class IndexOperationImportIdentity < ActiveRecord::Migration[8.1]
  def up
    add_index :operation_imports, [ :company_id, :sha256 ], unique: true, where: "state <> 'failed'", name: "operation_imports_active_file"
    execute <<~SQL
      CREATE INDEX operation_rows_pending_group_key
      ON operation_import_rows (operation_import_id, (data->>'group_key'))
      WHERE operation_import_group_id IS NULL
    SQL
  end

  def down
    execute "DROP INDEX operation_rows_pending_group_key"
    remove_index :operation_imports, name: "operation_imports_active_file"
  end
end
