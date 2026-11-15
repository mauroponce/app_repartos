class AddCompanyImportProvince < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :province, :string, null: false, default: "Buenos Aires"
    add_check_constraint :companies, "length(btrim(province)) > 0 AND length(province) <= 100", name: "company_province_present"
    add_check_constraint :customer_import_rows, "review_state <> 'automatic' OR (precision = 'reliable' AND latitude IS NOT NULL AND longitude IS NOT NULL)", name: "customer_import_row_automatic"
  end
end
