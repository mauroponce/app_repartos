require "csv"

class CustomerImportsController < ManagementController
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  before_action :set_import, only: %i[show update confirm errors]

  def new
  end

  def template
    send_data CSV.generate { |csv| csv << CustomerImporter::FIELDS.map { |field| CustomerImporter::LABELS.fetch(field) }; csv << [ "000123", "Almacén Sur", "Ana", nil, "pedidos@example.com", "Av. Mitre 123", "Avellaneda", nil, nil, "activo" ] }, filename: "plantilla_clientes.csv", type: "text/csv; charset=utf-8"
  end

  def create
    data = CustomerImportReader.call(params[:file])
    import = Current.company.customer_imports.create!(**data, mapping: CustomerImporter.default_mapping(data[:headers]))
    redirect_to customer_import_path(import), status: :see_other
  rescue CustomerImportReader::InvalidFile => error
    flash.now[:alert] = error.message
    render :new, status: :unprocessable_entity
  end

  def show
    prepare_preview
  end

  def update
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
    render :show, status: :unprocessable_entity
  end

  def confirm
    CustomerImporter.new(@customer_import).confirm!(preview_digest: params[:preview_digest], acknowledge_duplicates: params[:acknowledge_duplicates] == "1")
    redirect_to customer_import_path(@customer_import), notice: "Importación confirmada. Reintentar no vuelve a crear clientes.", status: :see_other
  rescue CustomerImporter::InvalidImport, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    flash.now[:alert] = error.message
    prepare_preview
    render :show, status: :unprocessable_entity
  end

  def errors
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

  def safe_cell(value)
    value.to_s.match?(/\A[=+\-@\t\r\n]/) ? "'#{value}" : value
  end
end
