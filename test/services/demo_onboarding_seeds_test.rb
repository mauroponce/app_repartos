require "test_helper"

class DemoOnboardingSeedsTest < ActiveSupport::TestCase
  test "demo stays idempotent across dates and preserves credentials manual edits assignments and history" do
    with_environment("development") do
      company = DemoOnboardingSeeds.call
      assert_equal [ 30, 16, 3, 20, 20, 3 ], counts(company)
      assert_equal [ 6, 6, 6 ], company.delivery_runs.order(:id).map { |run| run.visits.count }
      assert_equal 18, company.customers.select(&:routing_location?).size
      assert company.customers.where.not(latitude: nil).all? { |customer| customer.contact.include?("sintético") }
      assert company.delivery_runs.all? { |run| run.assigned? && !run.routing_blocked? }
      schedule = company.delivery_schedules.order(:id).first
      assert_equal "08:00", schedule.window_start.strftime("%H:%M")
      assert_equal "12:00", schedule.window_end.strftime("%H:%M")
      customer = company.customers.order(:id).first
      customer.update!(name: "Editado manualmente")
      driver = company.users.driver.order(:id).first
      driver.update!(password: "Password-changed-2026", email_address: "editado@piloto.test")
      schedule.update!(notes: "Observaciones editadas manualmente")
      product = company.products.order(:id).first
      product.update!(sku: "SKU-EDITADO")
      platform_admin = PlatformAdmin.find_by!(email_address: DemoOnboardingSeeds::PLATFORM_EMAIL)
      platform_admin.update!(email_address: "propietario-editado@repartos.test")
      run = company.delivery_runs.order(:id).first
      run.update!(driver: company.users.driver.order(:id).last)
      before = [ company.users.pluck(:id, :password_digest), company.delivery_runs.pluck(:id, :driver_id, :scheduled_date), company.delivery_orders.pluck(:id) ]
      travel 3.weeks do
        DemoOnboardingSeeds.call
      end
      assert_equal [ 30, 16, 3, 20, 20, 3 ], counts(company)
      assert_equal "Editado manualmente", customer.reload.name
      assert driver.reload.authenticate("Password-changed-2026")
      assert_equal "Observaciones editadas manualmente", schedule.reload.notes
      assert_equal "SKU-EDITADO", product.reload.sku
      assert_equal "editado@piloto.test", driver.email_address
      assert_equal 1, PlatformAdmin.count
      assert_equal before, [ company.users.pluck(:id, :password_digest), company.delivery_runs.pluck(:id, :driver_id, :scheduled_date), company.delivery_orders.pluck(:id) ]
      manual_schedule = company.delivery_schedules.create!(customer: customer, weekday: 1, starts_on: schedule.starts_on,
        notes: "Creada por usuario", delivery_schedule_items_attributes: [ { product: company.products.first, quantity: 4 } ])
      DemoOnboardingSeeds.call
      assert_empty manual_schedule.delivery_orders
      assert_equal 20, company.delivery_orders.count
    end
  end

  test "demo is disabled in production and test and production seeds return without privileged accounts" do
    %w[production test].each do |environment|
      with_environment(environment) do
        assert_no_difference [ "PlatformAdmin.count", "Company.count", "User.count" ] do
          assert_nil DemoOnboardingSeeds.call
          load Rails.root.join("db/seeds.rb")
        end
      end
    end
  end

  private

  def with_environment(environment)
    original = Rails.method(:env)
    Rails.define_singleton_method(:env) { environment.inquiry }
    yield
  ensure
    Rails.define_singleton_method(:env, original)
  end

  def counts(company)
    [ company.customers.count, company.products.count, company.users.driver.count, company.delivery_schedules.count, company.delivery_orders.count, company.delivery_runs.count ]
  end
end
