module DeliveryUnits
  LABELS = { "unit" => "unidad", "pack" => "paquete", "bag" => "bolsa", "box" => "caja", "kg" => "kilogramo", "g" => "gramo", "l" => "litro" }.freeze
  DISCRETE = %w[unit pack bag box].freeze
  CODES = LABELS.keys.freeze

  def self.options
    LABELS.map { |code, label| [ "#{label} (#{code})", code ] }
  end
end
