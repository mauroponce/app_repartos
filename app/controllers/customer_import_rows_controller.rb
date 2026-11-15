class CustomerImportRowsController < ManagementController
  before_action :set_row

  def edit
    @next_row = @customer_import.import_rows.where(excluded: false, customer_id: nil, review_state: "pending").where("number > ?", @row.number).order(:number).first
  end

  def update
    @customer_import.with_lock do
      raise CustomerImports::Workflow::Invalid, "El lote no admite cambios." unless @customer_import.editable? && @row.customer_id.nil?
      @row.lock!
      if params[:decision] == "exclude"
        @row.update!(excluded: true)
      else
        attributes = params.expect(row: [ :name, :contact, :phone, :email, :external_code, :address, :city, :latitude, :longitude, :status ]).to_h
        data = @row.data.merge(attributes.except("latitude", "longitude").transform_values { |value| Geocoding::Address.clean(value).first(255) })
        data["province"] = Current.company.province
        data["country"] = "Argentina"
        customer = Current.company.customers.new(data.slice(*CustomerImporter::FIELDS).except("latitude", "longitude"))
        customer.valid?
        changes = { data: data, excluded: false, issues: customer.errors.full_messages }
        case params[:decision]
        when "manual"
          lat, lon = attributes.values_at("latitude", "longitude")
          unless Geocoding::Address.valid_point?(lat, lon, country: "Argentina") && Geocoding::ProvinceBoundary.contains?(Current.company.province, lat, lon)
            raise CustomerImports::Workflow::Invalid, "Ingresá un punto válido dentro de #{Current.company.province}."
          end
          changes.merge!(latitude: lat, longitude: lon, manual_confirmation: true, review_state: "manual", provider: "manual")
        when "unlocated"
          changes.merge!(latitude: nil, longitude: nil, manual_confirmation: false, review_state: "unlocated", precision: "unlocated", provider: nil)
        else
          raise CustomerImports::Workflow::Invalid, "Elegí confirmar la ubicación o mantenerla pendiente."
        end
        changes[:normalized] = Geocoding::Address.normalize(data, @customer_import.geographic_context)
        @row.update!(changes)
      end
    end
    next_row = @customer_import.import_rows.where(excluded: false, customer_id: nil, review_state: "pending").where("number > ?", @row.number).order(:number).first
    if params[:next] == "1" && next_row
      redirect_to edit_customer_import_row_path(@customer_import, next_row), notice: "Fila guardada.", status: :see_other
    else
      redirect_to customer_import_path(@customer_import), notice: "Fila guardada.", status: :see_other
    end
  rescue CustomerImports::Workflow::Invalid, ActiveRecord::RecordInvalid => error
    redirect_to edit_customer_import_row_path(@customer_import, @row), alert: error.message, status: :see_other
  end

  private

  def set_row
    response.headers["Cache-Control"] = "no-store"
    @customer_import = Current.company.customer_imports.find(params[:customer_import_id])
    @row = @customer_import.import_rows.find(params[:id])
  end
end
