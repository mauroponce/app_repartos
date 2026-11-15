require "csv"
require "roo"

class ProductImportReader
  MAX_BYTES = 5.megabytes
  MAX_ROWS = 1_000
  MAX_COLUMNS = 30
  class InvalidFile < StandardError; end

  def initialize(max_bytes: MAX_BYTES, max_rows: MAX_ROWS, max_columns: MAX_COLUMNS)
    @max_bytes, @max_rows, @max_columns = max_bytes, max_rows, max_columns
  end

  def self.call(upload)
    new.call(upload)
  end

  def call(upload)
    raise InvalidFile, "Seleccioná un archivo CSV o XLSX de hasta #{@max_bytes / 1.megabyte} MB." unless upload.respond_to?(:original_filename) && upload.respond_to?(:read) && upload.respond_to?(:size) && upload.size.positive? && upload.size <= @max_bytes
    extension = File.extname(upload.original_filename).downcase
    table = case extension
    when ".csv" then read_csv(upload)
    when ".xlsx" then read_xlsx(upload)
    else raise InvalidFile, "El formato debe ser CSV o XLSX."
    end
    raise InvalidFile, "El archivo debe tener encabezados y al menos una fila." if table.size < 2
    headers = table.shift.map { |value| value.to_s.strip }
    raise InvalidFile, "Se admiten hasta #{@max_columns} columnas." if headers.size > @max_columns
    raise InvalidFile, "Hay encabezados vacíos o repetidos." if headers.any?(&:blank?) || headers.uniq.size != headers.size
    raise InvalidFile, "Los encabezados admiten hasta 255 caracteres." if headers.any? { |header| header.size > 255 }
    rows = table
    raise InvalidFile, "El archivo no tiene registros." if rows.all? { |row| row.all?(&:blank?) }
    raise InvalidFile, "Se admiten hasta #{@max_rows} registros por archivo." if rows.size > @max_rows
    raise InvalidFile, "Hay filas con más columnas que encabezados." if rows.any? { |row| row.size > headers.size }
    raise InvalidFile, "Una celda supera el tamaño permitido (10 KB)." if rows.any? { |row| row.any? { |cell| cell.to_s.bytesize > 10_000 } }
    { headers: headers, rows: rows.map { |row| row.map { |cell| cell.to_s.strip } } }
  rescue CSV::MalformedCSVError, EncodingError, ArgumentError, Zip::Error, Roo::FileNotFound, Roo::Excelx::ExceedsMaxError, Nokogiri::XML::SyntaxError, IOError, TypeError => e
    raise InvalidFile, "No se pudo leer el archivo. Verificá su formato y codificación UTF-8."
  end

  private

  def read_csv(upload)
    content = upload.read(@max_bytes + 1).force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF")
    raise InvalidFile, "El archivo supera el tamaño permitido." if content.bytesize > @max_bytes
    raise InvalidFile, "El CSV debe usar codificación UTF-8." unless content.valid_encoding?
    raise InvalidFile, "El CSV contiene datos binarios." if content.include?("\0")
    separator = content.lines.first.to_s.count(";") > content.lines.first.to_s.count(",") ? ";" : ","
    table = []
    CSV.parse(content, col_sep: separator, field_size_limit: 10_000) do |row|
      table << row
      raise InvalidFile, "Se admiten hasta #{@max_rows} registros por archivo." if table.size > @max_rows + 1
      raise InvalidFile, "Se admiten hasta #{@max_columns} columnas." if row.size > @max_columns
    end
    table
  end

  def read_xlsx(upload)
    validate_archive!(upload.path)
    book = Roo::Excelx.new(upload.path, file_warning: :ignore, cell_max: (@max_rows + 1) * @max_columns)
    sheet = book.sheet(0)
    raise InvalidFile, "La primera hoja está vacía." unless sheet.last_row
    raise InvalidFile, "Se admiten hasta #{@max_rows} filas y #{@max_columns} columnas." if sheet.last_row > @max_rows + 1 || sheet.last_column > @max_columns
    (1..sheet.last_row).map do |row|
      (1..sheet.last_column).map do |column|
        value = sheet.cell(row, column)
        # Excel commonly stores customer codes as numbers with a zero mask.
        # Apply only that safe format; never evaluate formulas or arbitrary formats.
        next sheet.formatted_value(row, column) if value.is_a?(Numeric) && sheet.excelx_format(row, column).to_s.match?(/\A0{2,100}\z/)
        # Avoid turning a numeric SKU such as 123 into "123.0".
        value.is_a?(Float) && value.finite? && value == value.to_i ? value.to_i.to_s : value
      end
    end
  ensure
    book&.close
  end

  def validate_archive!(path)
    Zip::File.open(path) do |zip|
      if zip.entries.size > 200 || zip.entries.sum(&:size) > 20.megabytes || zip.find_entry("xl/workbook.xml").nil?
        raise InvalidFile, "El XLSX no es válido o supera el tamaño descomprimido permitido (20 MB)."
      end
      # Do not trust the sizes declared in a ZIP's directory. Bound the actual
      # inflation before handing the archive to Roo/Nokogiri.
      inflated = 0
      zip.each do |entry|
        raise InvalidFile, "El XLSX contiene rutas o referencias externas no admitidas." if entry.name.start_with?("/", "\\") || entry.name.split(/[\\\/]/).include?("..") || entry.name.start_with?("xl/externalLinks/") || entry.ftype == :symlink
        entry.get_input_stream do |stream|
          while (chunk = stream.read(64.kilobytes))
            inflated += chunk.bytesize
            raise InvalidFile, "El XLSX supera 20 MB descomprimidos." if inflated > 20.megabytes
          end
        end
      end
    end
  end
end
