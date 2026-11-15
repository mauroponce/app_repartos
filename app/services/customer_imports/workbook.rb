require "csv"
require "roo"

module CustomerImports
  class Workbook < ProductImportReader
    MIME_TYPES = %w[text/csv application/csv text/plain application/octet-stream application/vnd.openxmlformats-officedocument.spreadsheetml.sheet].freeze
    InvalidFile = ProductImportReader::InvalidFile

    def self.validate_upload!(upload)
      unless upload.respond_to?(:original_filename) && upload.respond_to?(:size) && upload.size.positive? && upload.size <= CustomerImportReader.max_bytes &&
          File.extname(upload.original_filename).downcase.in?(%w[.csv .xlsx]) && upload.content_type.to_s.in?(MIME_TYPES)
        raise InvalidFile, "Seleccioná un CSV o XLSX de hasta #{CustomerImportReader.max_bytes / 1.megabyte} MB."
      end
    end

    def initialize(path, filename)
      super(max_rows: CustomerImportReader.max_rows, max_bytes: CustomerImportReader.max_bytes, max_columns: 30)
      @path, @extension = path.to_s, File.extname(filename.to_s).downcase
      raise InvalidFile, "Archivo demasiado grande." if File.size(path) > @max_bytes
      validate_archive!(@path) if @extension == ".xlsx"
    end

    def metadata(sheet_index: 0, header_row: nil)
      first = []
      each_raw(sheet_index) { |values, number| first << [ values, number ]; break if first.size >= 20 }
      raise InvalidFile, "La hoja está vacía." if first.empty?
      detected = if header_row
        Integer(header_row)
      else
        first.max_by { |values, _| CustomerImporter.default_mapping(values.map(&:to_s)).size * 10 + values.count(&:present?) }.last
      end
      raise InvalidFile, "La fila de encabezados debe estar entre 1 y 20." unless detected.between?(1, 20)
      values = first.find { |_, number| number == detected }&.first
      raise InvalidFile, "No encontramos los encabezados." unless values&.any?(&:present?)
      headers = values.each_with_index.map { |value, index| Geocoding::Address.clean(value).first(255).presence || "Columna #{index + 1}" }
      # Repeated column names remain selectable by index; make their labels unique.
      headers = headers.each_with_index.map { |header, index| headers.count(header) > 1 ? "#{header} (#{index + 1})" : header }
      { headers: headers, header_row: detected, sheet_names: sheet_names }
    rescue ArgumentError
      raise InvalidFile, "Hoja o encabezados inválidos."
    end

    def each_record(sheet_index:, header_row:)
      count = 0
      each_raw(sheet_index) do |values, number|
        next if number <= header_row
        count += 1
        raise InvalidFile, "Se admiten hasta #{@max_rows} registros." if count > @max_rows
        yield values, number
      end
      raise InvalidFile, "La hoja no contiene registros." if count.zero?
    end

    private

    def sheet_names
      return [ "CSV" ] if @extension == ".csv"
      book = Roo::Excelx.new(@path, file_warning: :ignore)
      book.sheets.first(30)
    ensure
      book&.close
    end

    def each_raw(sheet_index)
      if @extension == ".csv"
        File.open(@path, "r:bom|utf-8") do |file|
          first = file.readline
          file.rewind
          separator = first.count(";") > first.count(",") ? ";" : ","
          CSV.new(file, col_sep: separator, field_size_limit: 10_000).each.with_index(1) do |row, number|
            validate_values!(row)
            yield row.map { |value| value.to_s }, number
          end
        end
      else
        book = Roo::Excelx.new(@path, file_warning: :ignore)
        index = Integer(sheet_index)
        raise InvalidFile, "Hoja inválida." unless index.between?(0, [ book.sheets.size - 1, 29 ].min)
        sheet = book.sheet(index)
        sheet.each_row_streaming(pad_cells: false).with_index(1) do |streamed_cells, index|
          number = streamed_cells.first&.coordinate&.row || index
          if number > @max_rows + 20 || streamed_cells.any? { |cell| cell.coordinate.column > @max_columns }
            raise InvalidFile, "La hoja supera el límite de filas o columnas."
          end
          cells = []
          streamed_cells.each { |cell| cells[cell.coordinate.column - 1] = cell }
          values = cells.map do |cell|
            next "" unless cell
            raise InvalidFile, "La fila #{number} contiene fórmulas. Exportá sus valores a CSV o quitá las fórmulas." if cell.formula?
            value = cell.value
            if value.is_a?(Numeric) && cell.respond_to?(:format) && cell.format.to_s.match?(/\A0{2,100}\z/)
              next cell.formatted_value
            end
            value.is_a?(Float) && value.finite? && value == value.to_i ? value.to_i.to_s : value.to_s
          end
          validate_values!(values)
          yield values, number
        end
      end
    rescue CSV::MalformedCSVError, EncodingError, EOFError, Zip::Error, Roo::Excelx::ExceedsMaxError, Nokogiri::XML::SyntaxError, ArgumentError, TypeError, NoMethodError, KeyError => error
      raise InvalidFile, "No se pudo leer la planilla. Revisá su formato, codificación y límites."
    ensure
      book&.close
    end

    def validate_values!(values)
      raise InvalidFile, "Se admiten hasta 30 columnas." if values.size > @max_columns
      if values.any? { |value| !value.to_s.valid_encoding? || value.to_s.include?("\0") || value.to_s.bytesize > 10_000 }
        raise InvalidFile, "Una celda contiene datos binarios, codificación inválida o más de 10 KB."
      end
    end
  end
end
