class RequireCommercialSnapshotSources < ActiveRecord::Migration[8.1]
  def change
    # SQL CHECK accepts NULL, so require a non-null source explicitly when
    # either historical amount is known. Unknown legacy amounts remain valid.
    [ :delivery_order_items, :delivery_items ].each do |table|
      add_check_constraint table, "(unit_price IS NULL AND unit_cost IS NULL) OR commercial_source IS NOT NULL", name: "#{table}_known_value_source"
    end
    add_check_constraint :delivery_runs, "currency IS NULL OR currency IN ('ARS','USD','EUR')", name: "runs_currency"
  end
end
