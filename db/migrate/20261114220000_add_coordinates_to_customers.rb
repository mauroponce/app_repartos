class AddCoordinatesToCustomers < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :latitude, :decimal, precision: 10, scale: 7
    add_column :customers, :longitude, :decimal, precision: 10, scale: 7
    add_check_constraint :customers, <<~SQL.squish, name: "customers_valid_coordinates"
      (latitude IS NULL AND longitude IS NULL) OR
      (latitude IS NOT NULL AND longitude IS NOT NULL AND
       latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)
    SQL
  end
end
