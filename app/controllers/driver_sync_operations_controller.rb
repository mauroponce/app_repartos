class DriverSyncOperationsController < ManagementController
  def index
    @operations = paginate(Current.company.driver_sync_operations.where(status: %w[conflict invalid]).includes(:user).order(created_at: :desc))
  end

  def show
    @operation = Current.company.driver_sync_operations.find(params[:id])
    @visit = Current.company.visits.find_by(id: @operation.visit_id)
  end
end
