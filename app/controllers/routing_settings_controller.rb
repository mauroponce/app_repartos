class RoutingSettingsController < ManagementController
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  def edit
    @company = Current.company
  end

  def update
    @company = Current.company
    @company.with_lock do
      @company.update!(params.expect(company: [ :depot_latitude, :depot_longitude, :routing_departure, :routing_return_to_depot, :routing_preferred_tolerance, :routing_service_minutes ]))
    end
    redirect_to edit_routing_settings_path, notice: "Configuración de rutas actualizada.", status: :see_other
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_entity
  end
end
