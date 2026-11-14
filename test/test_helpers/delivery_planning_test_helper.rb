module DeliveryPlanningTestHelper
  def planned_run(company:, date:, driver: nil)
    orders = DeliveryOrderGenerator.call(company: company, date: date)
    run = company.delivery_runs.new(name: "Hoja de prueba", scheduled_date: orders.first&.scheduled_date || date, driver: driver, status: driver ? :assigned : :draft)
    DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: orders.map(&:id))
  end
end

ActiveSupport::TestCase.include DeliveryPlanningTestHelper
