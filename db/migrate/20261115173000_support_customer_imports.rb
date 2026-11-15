class SupportCustomerImports < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :external_code, :string
    change_column_null :customers, :phone, true
    add_check_constraint :customers, "external_code IS NULL OR (length(btrim(external_code)) > 0 AND length(external_code) <= 255)", name: "customers_external_code_present"
    create_table :customer_imports do |t|
      t.references :company, null: false, foreign_key: true
      t.jsonb :headers, null: false, default: []
      t.jsonb :rows, null: false, default: []
      t.jsonb :mapping, null: false, default: {}
      t.jsonb :excluded_rows, null: false, default: []
      t.boolean :overwrite_blanks, null: false, default: false
      t.jsonb :summary, null: false, default: {}
      t.datetime :confirmed_at
      t.timestamps
    end
  end
end
