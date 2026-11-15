class CustomerImportJob < ApplicationJob
  queue_as :customer_imports
  # One shared execution slot for all import stages, across worker processes.
  # HTTP quotas remain DB-enforced even for the optional integration command.
  limits_concurrency to: 1, key: ->(*) { "customer-imports" }, duration: 10.minutes
  retry_on ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished, wait: :polynomially_longer, attempts: 5

  def perform(company_id, import_id, generation, action)
    @import = CustomerImport.where(company_id: company_id).find_by(id: import_id)
    @generation = generation
    @action = action
    return unless @import && @import.generation == generation && (!@import.expired? || @import.state == "importing")
    expected = { "read" => "reading", "prepare" => "preparing", "process" => "processing", "commit" => "importing" }.fetch(action)
    return unless @import.state == expected
    @import.update_columns(heartbeat_at: Time.current)
    case action
    when "read" then read_file
    when "prepare" then prepare_rows
    when "process" then process_rows
    when "commit" then commit_rows
    end
  rescue Geocoding::Deferred => error
    self.class.set(wait: error.wait.seconds).perform_later(company_id, import_id, generation, action)
  rescue Geocoding::Retryable => error
    self.class.set(wait: error.wait.seconds).perform_later(company_id, import_id, generation, action)
  rescue Geocoding::Error => error
    fail_import(error.message)
  rescue CustomerImports::Workbook::InvalidFile => error
    fail_import(error.message)
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    fail_import("No se pudo recuperar el archivo original. Volvé a cargarlo.")
  rescue ActiveRecord::RecordInvalid, CustomerImports::Workflow::Invalid => error
    fail_import("No se pudo completar el lote. Revisá las filas y reanudá.")
    Rails.logger.warn("Customer import validation failed: #{error.class.name}")
  rescue ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished
    raise
  rescue StandardError => error
    fail_import("El procesamiento se interrumpió. Podés reanudar el lote sin duplicar clientes.")
    Rails.logger.error("Customer import failed: #{error.class.name}")
  end

  private

  def current?(state)
    @import.reload.generation == @generation && @import.state == state
  end

  def read_file
    @import.source_file.open do |file|
      workbook = CustomerImports::Workbook.new(file.path, @import.source_file.filename)
      metadata = workbook.metadata(sheet_index: @import.sheet_index, header_row: @import.header_row.zero? ? nil : @import.header_row)
      @import.with_lock do
        return unless current?("reading")
        @import.import_rows.delete_all
        @import.update!(**metadata, mapping: CustomerImports::Preparation.mapping(metadata[:headers]), total_rows: 0, processed_rows: 0)
      end
      buffer = []
      workbook.each_record(sheet_index: @import.sheet_index, header_row: @import.header_row) do |values, number|
        now = Time.current
        buffer << { company_id: @import.company_id, customer_import_id: @import.id, number: number, original: values, created_at: now, updated_at: now }
        if buffer.size >= 100
          return unless write_rows(buffer)
          buffer.clear
        end
      end
      return unless buffer.empty? || write_rows(buffer)
      @import.with_lock do
        return unless current?("reading")
        @import.update!(state: "mapping", total_rows: @import.import_rows.count, last_error: nil, heartbeat_at: Time.current)
      end
    end
  end

  def write_rows(buffer)
    @import.with_lock do
      return false unless current?("reading")
      CustomerImportRow.insert_all!(buffer)
      @import.update!(total_rows: @import.import_rows.count, heartbeat_at: Time.current)
    end
    true
  end

  def prepare_rows
    complete = CustomerImports::Preparation.call(@import)
    @import.with_lock do
      return unless current?("preparing")
      @import.update!(state: complete ? "processing" : "preparing", heartbeat_at: Time.current)
    end
    CustomerImports::Workflow.enqueue(@import, complete ? "process" : "prepare")
  end

  def process_rows
    rows = @import.import_rows.where(processed_at: nil).order(:id).limit(25).to_a
    pipeline = Geocoding::Pipeline.new(company_id: @import.company_id)
    # Bulk Georef first, including cache coalescing for repeated addresses.
    addresses = rows.reject { |row| row.excluded? || row.issues.any? || row.data["latitude"].present? }.map(&:normalized)
    begin
      pipeline.prefetch(addresses) if rows.all? { |row| row.attempts.zero? }
    rescue Geocoding::Deferred
      raise
    rescue Geocoding::Retryable => error
      rows.each { |row| row.increment!(:attempts) unless row.excluded? || row.issues.any? }
      self.class.set(wait: error.wait.seconds).perform_later(@import.company_id, @import.id, @generation, "process")
      return
    rescue Geocoding::Error
      # Individual pipeline invocations perform bounded retries and fallback.
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rows.each do |row|
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= 60
      return unless current?("processing")
      if row.excluded? || row.issues.any?
        persist_result(row, "precision" => "unlocated", "candidates" => [], "normalized" => row.normalized, "warnings" => [])
        next
      end
      begin
        result = pipeline.call(row.data, context: @import.geographic_context, attempts: row.attempts)
        persist_result(row, result)
      rescue Geocoding::Deferred
        raise
      rescue Geocoding::Retryable => error
        row.increment!(:attempts)
        self.class.set(wait: [ error.wait, 5 * 2**row.attempts ].max.seconds).perform_later(@import.company_id, @import.id, @generation, "process")
        return
      end
    end
    @import.with_lock do
      return unless current?("processing")
      remaining = @import.import_rows.where(processed_at: nil).exists?
      @import.update!(state: remaining ? "processing" : "review", processed_rows: @import.import_rows.where.not(processed_at: nil).count, heartbeat_at: Time.current)
    end
    CustomerImports::Workflow.enqueue(@import, "process") if @import.state == "processing"
  end

  def persist_result(row, result)
    candidate = result["candidate"] || {}
    normalized = result.fetch("normalized")
    data = row.data.merge("city" => row.data["city"].presence || normalized["city"])
    customer = @import.company.customers.new(data.slice(*CustomerImporter::FIELDS).except("latitude", "longitude"))
    customer.valid?
    @import.with_lock do
      return unless current?("processing")
      row.update!(data: data, normalized: normalized, precision: result.fetch("precision"), candidates: result.fetch("candidates"),
        provider: candidate["provider"], latitude: candidate["latitude"], longitude: candidate["longitude"],
        review_state: result["precision"] == "reliable" ? "automatic" : "pending",
        issues: (row.issues + customer.errors.full_messages).uniq,
        warnings: (row.warnings + result.fetch("warnings", [])).uniq, processed_at: Time.current)
      @import.update!(processed_rows: @import.import_rows.where.not(processed_at: nil).count, heartbeat_at: Time.current)
    end
  end

  def commit_rows
    @import.import_rows.where(excluded: false, customer_id: nil).order(:id).limit(50).each do |row|
      @import.company.with_lock do
        @import.with_lock do
          return unless current?("importing")
          row.lock!
          next if row.customer_id
          attributes = row.data.slice(*CustomerImporter::FIELDS).except("latitude", "longitude")
          attributes["latitude"], attributes["longitude"] = row.latitude, row.longitude if row.verified? || row.provider == "user"
          attributes["location_verification"] = if row.manual_confirmation? then "manual"
          elsif row.verified? then "reliable"
          elsif row.provider == "user" then "provided"
          else "pending"
          end
          if attributes["latitude"] && !Geocoding::ProvinceBoundary.contains?(@import.company.province, attributes["latitude"], attributes["longitude"])
            raise ActiveRecord::RecordInvalid.new(@import.company.customers.new)
          end
          customer = @import.company.customers.create!(attributes)
          row.update!(customer: customer)
          @import.update!(heartbeat_at: Time.current)
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      @import.with_lock do
        row.update!(issues: (row.issues + [ "El cliente no pudo crearse: revisá los datos o un código externo que ya existe." ]).uniq)
        @import.update!(state: "review", last_error: "Hay filas para corregir. Los clientes ya creados están protegidos contra duplicación.")
      end
      return
    end
    @import.with_lock do
      return unless current?("importing")
      unless @import.import_rows.where(excluded: false, customer_id: nil).exists?
        created = @import.import_rows.where.not(customer_id: nil)
        summary = { "created" => created.count, "updated" => 0, "skipped" => @import.import_rows.where(excluded: true).count,
          "pending_location" => created.where.not(review_state: %w[manual automatic]).count,
          "reliable" => created.where(review_state: "automatic").count,
          "manual" => created.where(review_state: "manual").count,
          "approximate" => created.where(precision: "approximate", manual_confirmation: false).count,
          "ambiguous" => created.where(precision: "ambiguous", manual_confirmation: false).count,
          "unlocated" => created.where(precision: "unlocated", manual_confirmation: false).count, "errors" => 0 }
        @import.update!(state: "completed", confirmed_at: Time.current, summary: summary, heartbeat_at: Time.current)
      end
    end
    CustomerImports::Workflow.enqueue(@import, "commit") if @import.state == "importing"
  end

  def fail_import(message)
    return unless @import
    @import.with_lock do
      @import.update!(state: "failed", last_error: message, heartbeat_at: Time.current, summary: @import.summary.merge("resume_state" => { "read" => "reading", "prepare" => "preparing", "process" => "processing", "commit" => "review" }[@action])) if @import.generation == @generation && @import.working?
    end
  end
end
