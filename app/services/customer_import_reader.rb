class CustomerImportReader
  InvalidFile = ProductImportReader::InvalidFile

  def self.max_rows
    Integer(ENV.fetch("CUSTOMER_IMPORT_MAX_ROWS", "5000")).clamp(1, 10_000)
  end

  def self.max_bytes
    Integer(ENV.fetch("CUSTOMER_IMPORT_MAX_MB", "5")).clamp(1, 20).megabytes
  end

  def self.call(upload)
    if upload.respond_to?(:content_type) && upload.content_type.present? && !upload.content_type.in?(%w[text/csv application/csv text/plain application/octet-stream application/vnd.openxmlformats-officedocument.spreadsheetml.sheet])
      raise InvalidFile, "El tipo de archivo debe ser CSV o XLSX."
    end
    ProductImportReader.new(max_bytes: max_bytes, max_rows: max_rows, max_columns: 30).call(upload)
  end
end
