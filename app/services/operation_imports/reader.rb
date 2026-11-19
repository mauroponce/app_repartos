require "csv"
require "roo"
require "zip"

module OperationImports
  class Reader
    InvalidFile = Class.new(StandardError)
    HEADERS = %w[repartidor cliente tipo_pedido fecha_puntual dia_semana hora_desde hora_hasta localidad calle nombre_producto cantidad_producto codigo_cliente referencia_pedido orden_visita].freeze
    MAX_ROWS = 50_000
    MAX_BYTES = 25.megabytes
    MAX_SHARED_BYTES = 30.megabytes

    def self.validate_upload!(upload)
      raise InvalidFile, "Seleccioná un archivo CSV o XLSX." unless upload
      extension = File.extname(upload.original_filename.to_s).downcase
      unless extension.in?(%w[.csv .xlsx]) && upload.size.to_i.between?(1, MAX_BYTES) &&
          upload.content_type.to_s.in?(%w[text/csv application/csv text/plain application/octet-stream application/vnd.openxmlformats-officedocument.spreadsheetml.sheet])
        raise InvalidFile, "Seleccioná un CSV o XLSX de hasta 25 MB."
      end
    end

    def initialize(path, filename)
      @path = path
      @extension = File.extname(filename.to_s).downcase
      raise InvalidFile, "Archivo demasiado grande" if File.size(path) > MAX_BYTES
      validate_zip! if @extension == ".xlsx"
    end

    def each_row
      headers = nil
      count = 0
      each_raw do |values, number|
        next if values.all?(&:blank?)
        if headers.nil?
          headers = values.map { |value| value.to_s.strip.downcase }
          raise InvalidFile, "Encabezados incompletos, duplicados o desconocidos" unless headers.sort == HEADERS.sort
          next
        end
        count += 1
        raise InvalidFile, "Se admiten hasta #{MAX_ROWS} filas" if count > MAX_ROWS
        raise InvalidFile, "Fila #{number} con demasiadas columnas" if values.size > HEADERS.size
        yield headers.zip(values.map { |value| value.to_s.strip }).to_h, number
      end
      raise InvalidFile, "La planilla no contiene registros" if count.zero?
    rescue CSV::MalformedCSVError, EncodingError, Zip::Error, Roo::Excelx::ExceedsMaxError, Nokogiri::XML::SyntaxError => error
      raise InvalidFile, "No se pudo leer la planilla: #{error.class.name}"
    end

    private

    def each_raw
      if @extension == ".csv"
        File.open(@path, "r:bom|utf-8") do |file|
          first = file.gets.to_s
          file.rewind
          separator = first.count(";") > first.count(",") ? ";" : ","
          CSV.new(file, col_sep: separator, field_size_limit: 10_000).each.with_index(1) do |row, number|
            check!(row)
            yield row, number
          end
        end
      else
        Zip::File.open(@path) do |archive|
          strings = []
          if (shared = archive.find_entry("xl/sharedStrings.xml"))
            source = shared.get_input_stream.read(MAX_SHARED_BYTES + 1)
            raise InvalidFile, "XLSX con demasiados textos compartidos" if source.bytesize > MAX_SHARED_BYTES
            document = Nokogiri::XML(source) { |config| config.nonet }
            strings = document.xpath("//*[local-name()='si']").map { |node| node.xpath(".//*[local-name()='t']").map(&:text).join }
          end
          sheet = archive.find_entry("xl/worksheets/sheet1.xml")
          raise InvalidFile, "La primera hoja no existe" unless sheet
          sheet.get_input_stream do |stream|
            reader = Nokogiri::XML::Reader(stream)
            reader.each do |node|
              next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT && node.name.split(":").last == "row"
              number = node.attribute("r").to_i
              raise InvalidFile, "Demasiadas filas" if number > MAX_ROWS + 1
              row = Nokogiri::XML(node.outer_xml) { |config| config.nonet }
              values = []
              row.xpath("//*[local-name()='c']").each do |cell|
                raise InvalidFile, "Las fórmulas no están permitidas (fila #{number})" if cell.at_xpath("./*[local-name()='f']")
                letters = cell["r"].to_s[/\A[A-Z]+/]
                column = letters.to_s.chars.reduce(0) { |result, letter| result * 26 + letter.ord - 64 }
                raise InvalidFile, "Demasiadas columnas" unless column.between?(1, HEADERS.size)
                value = if cell["t"] == "inlineStr"
                  cell.xpath(".//*[local-name()='t']").map(&:text).join
                else
                  cell.at_xpath("./*[local-name()='v']")&.text.to_s
                end
                value = strings.fetch(value.to_i, "") if cell["t"] == "s"
                values[column - 1] = value
              end
              check!(values)
              yield values, number
            end
          end
        end
      end
    end

    def check!(values)
      raise InvalidFile, "Demasiadas columnas" if values.size > HEADERS.size
      if values.any? { |value| !value.to_s.valid_encoding? || value.to_s.include?("\0") || value.to_s.bytesize > 10_000 }
        raise InvalidFile, "Celda inválida o demasiado extensa"
      end
    end

    def validate_zip!
      inflated = 0
      Zip::File.open(@path) do |archive|
        raise InvalidFile, "XLSX inválido" unless archive.find_entry("xl/workbook.xml") && archive.entries.size <= 500
        archive.each do |entry|
          if entry.name.start_with?("/", "\\") || entry.name.split(/[\\\/]/).include?("..") || entry.name.start_with?("xl/externalLinks/") || entry.ftype == :symlink
            raise InvalidFile, "XLSX con contenido no admitido"
          end
          entry.get_input_stream do |stream|
            while (chunk = stream.read(64.kilobytes))
              inflated += chunk.bytesize
              raise InvalidFile, "XLSX demasiado grande al descomprimir" if inflated > 150.megabytes
            end
          end
        end
      end
    end
  end
end
