require "csv"
require "roo"

class ProductImportReader
  MAX_BYTES = 5.megabytes
  MAX_ROWS = 1_000
  MAX_COLUMNS = 30
  class InvalidFile < StandardError; end

  def self.call(upload)
    new.call(upload)
  end

  def call(upload)
    raise InvalidFile, "Seleccioná un archivo CSV o XLSX de hasta 5 MB." unless upload.respond_to?(:original_filename) && upload.respond_to?(:read) && upload.respond_to?(:size) && upload.size.positive? && upload.size <= MAX_BYTES
    extension = File.extname(upload.original_filename).downcase
    table = case extension
    when ".csv" then read_csv(upload)
    when ".xlsx" then read_xlsx(upload)
    else raise InvalidFile, "El formato debe ser CSV o XLSX."
    end
    raise InvalidFile, "El archivo debe tener encabezados y al menos una fila." if table.size < 2
    headers = table.shift.map { |value| value.to_s.strip }
    raise InvalidFile, "Se admiten hasta #{MAX_COLUMNS} columnas." if headers.size > MAX_COLUMNS
    raise InvalidFile, "Hay encabezados vacíos o repetidos." if headers.any?(&:blank?) || headers.uniq.size != headers.size
    rows = table
    raise InvalidFile, "El archivo no tiene productos." if rows.all? { |row| row.all?(&:blank?) }
    raise InvalidFile, "Se admiten hasta #{MAX_ROWS} productos por archivo." if rows.size > MAX_ROWS
    raise InvalidFile, "Hay filas con más columnas que encabezados." if rows.any? { |row| row.size > headers.size }
    { headers: headers, rows: rows.map { |row| row.map { |cell| cell.to_s.strip } } }
  rescue CSV::MalformedCSVError, EncodingError, ArgumentError, Zip::Error, Roo::FileNotFound, Roo::Excelx::ExceedsMaxError, Nokogiri::XML::SyntaxError, IOError, TypeError => e
    raise InvalidFile, "No se pudo leer el archivo. Verificá su formato y codificación UTF-8."
  end

  private

  def read_csv(upload)
    content = upload.read.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF")
    raise InvalidFile, "El CSV debe usar codificación UTF-8." unless content.valid_encoding?
    separator = content.lines.first.to_s.count(";") > content.lines.first.to_s.count(",") ? ";" : ","
    table = []
    CSV.parse(content, col_sep: separator, field_size_limit: 10_000) do |row|
      table << row
      raise InvalidFile, "Se admiten hasta #{MAX_ROWS} productos por archivo." if table.size > MAX_ROWS + 1
    end
    table
  end

  def read_xlsx(upload)
    Zip::File.open(upload.path) do |zip|
      if zip.entries.size > 200 || zip.entries.sum(&:size) > 20.megabytes || zip.find_entry("xl/workbook.xml").nil?
        raise InvalidFile, "El XLSX no es válido o supera el tamaño descomprimido permitido (20 MB)."
      end
    end
    book = Roo::Excelx.new(upload.path, file_warning: :ignore, cell_max: (MAX_ROWS + 1) * MAX_COLUMNS)
    sheet = book.sheet(0)
    raise InvalidFile, "La primera hoja está vacía." unless sheet.last_row
    raise InvalidFile, "Se admiten hasta #{MAX_ROWS} filas y #{MAX_COLUMNS} columnas." if sheet.last_row > MAX_ROWS + 1 || sheet.last_column > MAX_COLUMNS
    (1..sheet.last_row).map do |row|
      (1..sheet.last_column).map do |column|
        value = sheet.cell(row, column)
        # Avoid turning a numeric SKU such as 123 into "123.0".
        value.is_a?(Float) && value.finite? && value == value.to_i ? value.to_i.to_s : value
      end
    end
  ensure
    book&.close
  end
end
