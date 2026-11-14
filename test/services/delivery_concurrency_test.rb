require "test_helper"

class DeliveryConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  self.fixture_table_names = []

  setup do
    @company = Company.create!(name: "Concurrency test", slug: "concurrency-#{SecureRandom.hex(8)}")
    @customer = @company.customers.create!(name: "Customer", phone: "123", address: "Street 1", city: "City")
  end

  teardown do
    # This class commits data so separate connections can exercise real locks.
    # Delete only the tenant created by this test, in foreign-key order.
    [ DeliveryItem, Visit, DeliveryRun, DeliveryScheduleItem, DeliverySchedule, ProductImport, Product ].each do |model|
      model.where(company_id: @company.id).delete_all
    end
    @customer.destroy!
    @company.reload.destroy!
  end

  test "concurrent generation retries commit one run visit and item" do
    schedule = @company.delivery_schedules.create!(customer: @customer, weekday: 2, starts_on: "2026-01-01")
    schedule.delivery_schedule_items.create!(description: "Manual", unit: "pack", quantity: 20)
    ids = concurrently do
      DeliveryRunGenerator.call(company: Company.find(@company.id), date: "2026-11-17").id
    end
    assert_equal 1, ids.uniq.size
    assert_equal 1, @company.delivery_runs.count
    assert_equal 1, @company.visits.count
    assert_equal 1, DeliveryItem.where(company: @company).count
  end

  test "concurrent confirmation imports a preview only once" do
    product_import = @company.product_imports.create!(headers: %w[sku name unit], rows: [ [ "NEW", "Test", "kg" ] ], mapping: { sku: "0", name: "1", unit: "2" })
    results = concurrently do
      ProductImporter.new(ProductImport.find(product_import.id)).confirm!
    end
    assert_equal [ 0, 1 ], results.sort
    assert_equal 1, @company.products.count
    assert product_import.reload.confirmed_at
  end

  private

  def concurrently(&work)
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          work.call
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.map(&:value)
  ensure
    threads&.each(&:join)
  end
end
