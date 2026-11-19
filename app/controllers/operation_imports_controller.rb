require "digest"

class OperationImportsController < ManagementController
  before_action :set_import, only: %i[show confirm]

  def index
    @imports = Current.company.operation_imports.order(created_at: :desc).limit(25)
  end

  def new
    @imports = Current.company.operation_imports.order(created_at: :desc).limit(10)
  end

  def create
    upload = params[:file]
    OperationImports::Reader.validate_upload!(upload)
    sha = Digest::SHA256.file(upload.tempfile.path).hexdigest
    previous = Current.company.operation_imports.where(sha256: sha).where.not(state: "failed").order(:id).first
    return redirect_to operation_import_path(previous), notice: "Este archivo ya fue cargado." if previous
    batch = Current.company.operation_imports.create!(sha256: sha, initiated_by: Current.user)
    batch.source_file.attach(upload)
    OperationImportJob.perform_later(Current.company.id, batch.id, "read")
    redirect_to operation_import_path(batch), notice: "La planilla se está leyendo."
  rescue ActiveRecord::RecordNotUnique
    previous = Current.company.operation_imports.where(sha256: sha).where.not(state: "failed").first
    redirect_to operation_import_path(previous), notice: "Este archivo ya fue cargado."
  rescue OperationImports::Reader::InvalidFile => error
    redirect_to new_operation_import_path, alert: error.message
  end

  def show
    @counts = @import.groups.group(:state).count
    if @import.state.in?(%w[analyzing review])
      @customer_matches = @import.groups.where.not(customer_id: nil).distinct.count(:customer_id)
      @driver_matches = @import.groups.where.not(driver_profile_id: nil).distinct.count(:driver_profile_id)
    end
    states = %w[review pending ready imported duplicate excluded]
    @selected_state = states.include?(params[:state]) ? params[:state] : nil
    groups = @import.groups
    groups = groups.where(state: @selected_state) if @selected_state
    @groups = groups.order(Arel.sql("CASE state WHEN 'review' THEN 0 WHEN 'pending' THEN 1 WHEN 'ready' THEN 2 ELSE 3 END"), :id)
      .limit(50).offset(params[:page].to_i.clamp(0, 1000) * 50)
    @detected = @import.rows.select("COUNT(DISTINCT data->>'customer_key') AS customers_count,
      COUNT(DISTINCT data->>'driver_key') AS drivers_count,
      COUNT(DISTINCT NULLIF(data->>'product_key', '')) AS products_count,
      COUNT(DISTINCT data->>'geocode_address_key') AS addresses_count").take
    customer_keys = @groups.map { |group| group.data["address_identity_key"] }.compact.uniq
    customer_codes = @groups.filter_map { |group| group.data["codigo_cliente"].presence&.downcase }.uniq
    driver_keys = @groups.map { |group| group.data["driver_key"] }.compact.uniq
    customer_directory = Current.company.customers
    driver_directory = Current.company.driver_profiles
    @customers = (customer_directory.order(:name).limit(200).to_a + customer_directory.where(import_identity_key: customer_keys).limit(200).to_a +
      customer_directory.where("lower(external_code) IN (?)", customer_codes).limit(200).to_a)
      .uniq(&:id).sort_by(&:name)
    @drivers = (driver_directory.order(:name).limit(200).to_a + driver_directory.where(name_key: driver_keys).limit(200).to_a)
      .uniq(&:id).sort_by(&:name)
  end

  def confirm
    allowed = false
    @import.with_lock do
      if @import.state.in?(%w[review finished])
        @import.update!(state: "importing")
        allowed = true
      end
    end
    return redirect_to operation_import_path(@import), alert: "Esperá el análisis antes de confirmar." unless allowed
    OperationImportJob.perform_later(Current.company.id, @import.id, "commit")
    redirect_to operation_import_path(@import), notice: "Se están guardando los grupos válidos."
  end

  def template
    send_file Rails.root.join("docs/ejemplos/operacion/plantilla_importacion_operacion.xlsx"), filename: "plantilla_importacion_operacion.xlsx",
      type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", disposition: "attachment"
  end

  private

  def set_import
    @import = Current.company.operation_imports.find(params[:id])
  end
end
