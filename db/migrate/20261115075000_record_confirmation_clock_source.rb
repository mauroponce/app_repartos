class RecordConfirmationClockSource < ActiveRecord::Migration[8.1]
  def change
    add_column :visits, :recorded_at_source, :string
    add_check_constraint :visits, "recorded_at_source IS NULL OR (recorded_at_source IN ('device','server') AND recorded_at IS NOT NULL)", name: "visits_recorded_clock_source"
  end
end
