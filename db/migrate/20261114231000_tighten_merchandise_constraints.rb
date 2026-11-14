class TightenMerchandiseConstraints < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :products, name: "products_valid_package", expression: "(package_content_quantity IS NULL AND package_content_unit IS NULL) OR (package_content_quantity > 0 AND package_content_unit IS NOT NULL AND package_content_unit IN ('unit','pack','bag','box','kg','g','l'))"
    add_check_constraint :products, "(package_content_quantity IS NULL AND package_content_unit IS NULL) OR (package_content_quantity IS NOT NULL AND package_content_quantity > 0 AND package_content_quantity < 1000000000 AND package_content_unit IS NOT NULL AND package_content_unit IN ('unit','pack','bag','box','kg','g','l'))", name: "products_valid_package"
    add_check_constraint :delivery_schedule_items, "quantity < 1000000000 AND position >= 0", name: "schedule_items_finite_quantity_position"
    add_check_constraint :delivery_items, "planned_quantity < 1000000000 AND (delivered_quantity IS NULL OR delivered_quantity < 1000000000)", name: "items_finite_quantities"
    add_check_constraint :visits, "position >= 0", name: "visits_nonnegative_position"
  end
end
