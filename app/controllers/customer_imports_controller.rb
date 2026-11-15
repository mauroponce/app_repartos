require "csv"

class CustomerImportsController < ManagementController
  rescue_from CustomerImports::Workflow::Invalid, with: :workflow_error
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  before_action :set_import, only: %i[show update confirm errors start cancel resume]

  def new
    @recent_imports = Current.company.customer_imports.where.not(state: "legacy").order(created_at: :desc).limit(10)
  end

  def template
    send_data CSV.generate { |csv| csv << CustomerImporter::FIELDS.map { |field| CustomerImporter::LABELS.fetch(field) }; csv << [ "000123", "Almacén Sur", "Ana", nil, "pedidos@example.com", "Av. Mitre 123", "Avellaneda", nil, nil, "activo" ] }, filename: "plantilla_clientes.csv", type: "text/csv; charset=utf-8"
  end

  def create
    CustomerImports::Workbook.validate_upload!(params[:file])
    import = Current.company.customer_imports.create!(state: "reading", initiated_by: Current.user, header_row: 0, heartbeat_at: Time.current, source_file: params[:file])
    CustomerImports::Workflow.enqueue(import, "read")
    redirect_to customer_import_path(import), status: :see_other
  rescue CustomerImportReader::InvalidFile => error
    flash.now[:alert] = error.message
    render :new, status: :unprocessable_entity
  end

  def show
    if @customer_import.intelligent?
      prepare_results
    else
      prepare_preview
      render :legacy
    end
  end

  def update
    return configure_intelligent if @customer_import.intelligent?
    if @customer_import.confirmed_at || @customer_import.expired?
      return redirect_to customer_import_path(@customer_import), alert: "La importación está confirmada o vencida.", status: :see_other
    end
    @customer_import.with_lock do
      raise CustomerImporter::InvalidImport, "La importación está confirmada o vencida." if @customer_import.confirmed_at || @customer_import.expired?
      @customer_import.update!(mapping: params.expect(mapping: CustomerImporter::FIELDS).to_h,
        excluded_rows: Array(params[:excluded_rows]).map { |number| Integer(number.to_s, 10) }, overwrite_blanks: params[:overwrite_blanks] == "1")
    end
    redirect_to customer_import_path(@customer_import), status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError, CustomerImporter::InvalidImport => error
    flash.now[:alert] = error.message
    prepare_preview
    render :legacy, status: :unprocessable_entity
  end

  def confirm
    if @customer_import.intelligent?
      CustomerImports::Workflow.confirm!(@customer_import, acknowledge_duplicates: params[:acknowledge_duplicates] == "1", acknowledge_pending: params[:acknowledge_pending] == "1")
      return redirect_to customer_import_path(@customer_import), notice: "El alta definitiva se está procesando en segundo plano.", status: :see_other
    end
    CustomerImporter.new(@customer_import).confirm!(preview_digest: params[:preview_digest], acknowledge_duplicates: params[:acknowledge_duplicates] == "1")
    redirect_to customer_import_path(@customer_import), notice: "Importación confirmada. Reintentar no vuelve a crear clientes.", status: :see_other
  rescue CustomerImporter::InvalidImport, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    flash.now[:alert] = error.message
    prepare_preview
    render :legacy, status: :unprocessable_entity
  end

  def start
    CustomerImports::Workflow.start!(@customer_import)
    redirect_to customer_import_path(@customer_import), status: :see_other
  end

  def cancel
    CustomerImports::Workflow.cancel!(@customer_import)
    redirect_to customer_import_path(@customer_import), status: :see_other
  end

  def resume
    CustomerImports::Workflow.resume!(@customer_import)
    redirect_to customer_import_path(@customer_import), status: :see_other
  end

  def errors
    return intelligent_errors if @customer_import.intelligent?
    rows = CustomerImporter.new(@customer_import).preview
    csv = CSV.generate do |table|
      table << [ "Fila", "Omitida", "Errores", "Advertencias" ]
      rows.each { |row| table << [ row.number, row.excluded ? "Sí" : "No", safe_cell(row.errors.join("; ")), safe_cell(row.warnings.join("; ")) ] if row.errors.any? || row.warnings.any? }
    end
    send_data csv, filename: "errores_clientes_#{@customer_import.id}.csv", type: "text/csv; charset=utf-8"
  end

  private

  def set_import
    @customer_import = Current.company.customer_imports.find(params[:id])
  end

  def prepare_preview
    importer = CustomerImporter.new(@customer_import)
    @preview = importer.preview
    @preview_digest = importer.digest(@preview)
  end

  def prepare_results
    rows = @customer_import.import_rows
    @counts = rows.where(manual_confirmation: false).group(:precision).count
    @counts["manual"] = rows.where(manual_confirmation: true).count
    @error_count = rows.where("issues <> '[]'::jsonb").count
    @duplicate_count = rows.where("duplicates <> '[]'::jsonb").count
    @query = params[:q].to_s.strip.first(120)
    @precision = params[:precision].presence_in(CustomerImportRow::PRECISION_LABELS.keys + %w[manual errors duplicates pending])
    rows = case @precision
    when "errors" then rows.where("issues <> '[]'::jsonb")
    when "duplicates" then rows.where("duplicates <> '[]'::jsonb")
    when "pending" then rows.where(review_state: "pending", excluded: false)
    when "manual" then rows.where(manual_confirmation: true)
    when nil then rows
    else rows.where(precision: @precision, manual_confirmation: false)
    end
    if @query.present?
      rows = rows.where("data->>'name' ILIKE :q OR data->>'address' ILIKE :q OR normalized->>'city' ILIKE :q", q: "%#{CustomerImportRow.sanitize_sql_like(@query)}%")
    end
    @rows = paginate(rows.order(:number))
  end

  def configure_intelligent
    reread = false
    @customer_import.with_lock do
      raise CustomerImports::Workflow::Invalid, "Solo se puede configurar un lote pendiente de mapeo." unless @customer_import.state == "mapping" && !@customer_import.expired?
      sheet = params[:sheet_index].present? ? Integer(params[:sheet_index].to_s, 10) : @customer_import.sheet_index
      header = params[:header_row].present? ? Integer(params[:header_row].to_s, 10) : @customer_import.header_row
      raise CustomerImports::Workflow::Invalid, "Hoja o encabezados inválidos." unless sheet.between?(0, @customer_import.sheet_names.size - 1) && header.between?(1, 20)
      if sheet != @customer_import.sheet_index || header != @customer_import.header_row
        @customer_import.update!(sheet_index: sheet, header_row: header, state: "reading", generation: @customer_import.generation + 1, heartbeat_at: Time.current)
        reread = true
      else
        context = params.fetch(:geographic_context, ActionController::Parameters.new).permit(*Geocoding::Address::CONTEXT_FIELDS).to_h.transform_values { |value| Geocoding::Address.clean(value).first(255) }
        @customer_import.update!(mapping: params.expect(mapping: CustomerImports::Preparation::FIELDS).to_h, geographic_context: context.merge("province" => Current.company.province, "country" => "Argentina"))
      end
    end
    CustomerImports::Workflow.enqueue(@customer_import, "read") if reread
    redirect_to customer_import_path(@customer_import), status: :see_other
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    workflow_error(CustomerImports::Workflow::Invalid.new("Revisá el mapeo: cada columna puede utilizarse una sola vez."))
  end

  def intelligent_errors
    csv = CSV.generate do |table|
      table << [ "Fila", "Estado", "Errores", "Advertencias", "Duplicados" ]
      @customer_import.import_rows.find_each(batch_size: 100) do |row|
        next if row.issues.empty? && row.warnings.empty? && row.duplicates.empty?
        table << [ row.number, row.label, safe_cell(row.issues.join("; ")), safe_cell(row.warnings.join("; ")), safe_cell(row.duplicates.join("; ")) ]
      end
    end
    send_data csv, filename: "errores_clientes_#{@customer_import.id}.csv", type: "text/csv; charset=utf-8"
  end

  def workflow_error(error)
    redirect_to customer_import_path(@customer_import), alert: error.message, status: :see_other
  end

  def safe_cell(value)
    value.to_s.match?(/\A[=+\-@\t\r\n]/) ? "'#{value}" : value
  end
end
