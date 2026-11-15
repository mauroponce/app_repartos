class DeliveryReceiptsController < ApplicationController
  around_action ->(_controller, action) { Time.use_zone(Current.company.time_zone, &action) }

  def show
    @visit = Current.company.visits.includes(:confirmed_by, :delivery_run, :delivery_items).find(params[:id])
    raise ActiveRecord::RecordNotFound if @visit.pending? || !(Current.user.manages_customers? || @visit.confirmed_by_id == Current.user.id)
    @operation = Current.company.driver_sync_operations.status_synced.find_by(visit_id: @visit.id)
    @evidences = @operation ? @operation.delivery_evidences.with_attached_file.order(:id) : []
    response.headers["Cache-Control"] = "private, no-store"
    render layout: Current.user.manages_customers? ? "application" : "repartidor"
  end
end
