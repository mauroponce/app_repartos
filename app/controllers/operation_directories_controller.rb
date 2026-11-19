class OperationDirectoriesController < ManagementController
  def drivers
    @drivers = paginate(Current.company.driver_profiles.order(:name))
  end

  def schedules
    @schedules = paginate(Current.company.delivery_schedules.includes(:customer, :driver_profile).order(:weekday, :visit_order, :id))
    @item_counts = Current.company.delivery_schedule_items.where(delivery_schedule_id: @schedules.map(&:id)).group(:delivery_schedule_id).count
  end

  def locations
    @customers = paginate(Current.company.customers.order(:name))
  end
end
