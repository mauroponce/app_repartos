class DeliveryRunGenerator
  def self.call(company:, date:, driver: nil, delivery_run: nil, name: nil)
    new(company: company, date: date, driver: driver, delivery_run: delivery_run, name: name).call
  end

  def initialize(company:, date:, driver: nil, delivery_run: nil, name: nil)
    @company, @driver, @run, @name = company, driver, delivery_run, name
    @date = date.is_a?(Time) || date.is_a?(ActiveSupport::TimeWithZone) ? date.in_time_zone(company.time_zone).to_date : Date.iso8601(date.to_s)
  end

  def call
    # Serialize generation for the tenant, including concurrent retries. The
    # unique indexes remain the final guard for writes outside this service.
    @company.with_lock do
      if @run
        raise ArgumentError, "El reparto pertenece a otra empresa o fecha" unless @run.company_id == @company.id && @run.scheduled_date == @date
        @run.lock!
        raise ArgumentError, "El reparto debe estar en borrador o asignado" unless @run.draft? || @run.assigned?
      else
        @run = @company.delivery_runs.find_by(generation_key: "schedules:#{@date}")
        return @run if @run
        @run = @company.delivery_runs.create!(scheduled_date: @date, generation_key: "schedules:#{@date}", name: @name.presence || "Reparto #{@date.strftime('%d/%m/%Y')}", driver: @driver, status: @driver ? :assigned : :draft)
      end
      copy_schedules
      @run
    end
  end

  private

  def copy_schedules
    existing = @run.visits.where.not(delivery_schedule_id: nil).pluck(:delivery_schedule_id)
    position = @run.visits.maximum(:position).to_i
    @company.delivery_schedules.applicable_on(@date).includes(:customer, :delivery_schedule_items).order(:preferred_time, :window_start, :id).each do |schedule|
      next if existing.include?(schedule.id)
      position += 1
      visit = @run.visits.build(company: @company, customer: schedule.customer, delivery_schedule: schedule, position: position, notes: schedule.notes)
      schedule.delivery_schedule_items.each do |item|
        visit.delivery_items.build(company: @company, product_id: item.product_id, description: item.description, unit: item.unit, planned_quantity: item.quantity, copying_schedule_snapshot: true)
      end
      visit.save!
    end
  end
end
