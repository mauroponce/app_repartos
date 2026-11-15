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
    [ RoutePublication, RoutingCacheEntry, RouteOptimizationProposal, IncidentPhoto, InternalNotice, WorkflowEvent, WorkflowCommand, WorkflowTask, CommercialOpportunity, Incident, CommercialRuleSetting, NotificationEvent, CustomerNotification, CommunicationConsent, DeliveryStatusEvent, DeliveryRunCost, RunStockMovement,
      DriverSyncOperation, DeliveryItem, DeliveryOrderItem, DeliveryOrder, Visit, DeliveryRun, DeliveryScheduleItem, DeliverySchedule, ProductImport, Product ].each do |model|
      model.where(company_id: @company.id).delete_all
    end
    @customer.destroy!
    User.where(company_id: @company.id).delete_all
    @company.reload.destroy!
  end

  test "concurrent generation retries commit one order and item without a run" do
    schedule = @company.delivery_schedules.create!(customer: @customer, weekday: 2, starts_on: "2026-01-01")
    schedule.delivery_schedule_items.create!(description: "Manual", unit: "pack", quantity: 20)
    ids = concurrently do
      DeliveryOrderGenerator.call(company: Company.find(@company.id), date: "2026-11-17").first.id
    end
    assert_equal 1, ids.uniq.size
    assert_equal 0, @company.delivery_runs.count
    assert_equal 0, @company.visits.count
    assert_equal 0, DeliveryItem.where(company: @company).count
    assert_equal 1, @company.delivery_orders.count
    assert_equal 1, @company.delivery_order_items.count
  end

  test "concurrent planners cannot assign an order to two routes" do
    order = @company.delivery_orders.new(customer: @customer, scheduled_date: "2026-11-17")
    order.delivery_order_items.build(description: "Manual", unit: "pack", quantity: 20)
    order.save!
    results = concurrently do
      company = Company.find(@company.id)
      run = company.delivery_runs.new(name: "Concurrent", scheduled_date: "2026-11-17")
      begin
        DeliveryRunPlanner.call(company: company, delivery_run: run, order_ids: [ order.id ])
        :assigned
      rescue ArgumentError
        :unavailable
      end
    end
    assert_equal [ :assigned, :unavailable ], results.sort
    assert_equal 1, @company.delivery_runs.count
    assert_equal 1, @company.visits.count
    assert_equal 1, DeliveryItem.where(company: @company).count
    assert order.reload.visit_id
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

  test "concurrent visit submissions commit quantities and author once" do
    order, driver = order_for_execution
    visit = order.visit
    item = visit.delivery_items.first
    results = concurrently do
      begin
        DriverVisitRecorder.call(user: User.find(driver.id), visit_id: visit.id,
          attributes: { status: "completed", items: [ { id: item.id, delivered_quantity: 18 } ] })
        :recorded
      rescue DriverVisitRecorder::Conflict
        :conflict
      end
    end
    assert_equal [ :conflict, :recorded ], results.sort
    assert_equal 18, item.reload.delivered_quantity
    assert_equal driver.id, visit.reload.confirmed_by_id
    assert visit.confirmed_at
    assert order.reload.needs_attention?
    assert_equal "partial", order.fulfillment_result
  end

  test "concurrent rescheduling commits one successor and leaves the attempt untouched" do
    order, driver = order_for_execution
    visit = order.visit
    item = visit.delivery_items.first
    DriverVisitRecorder.call(user: driver, visit_id: visit.id, attributes: { status: "completed", items: [ { id: item.id, delivered_quantity: 18 } ] })
    snapshot = visit.reload.attributes
    ids = concurrently do
      DeliveryOrderRescheduler.call(company: Company.find(@company.id), order_id: order.id, date: order.scheduled_date + 1).id
    end
    assert_equal 1, ids.uniq.size
    assert_equal 2, @company.delivery_orders.count
    assert_equal 2, @company.delivery_order_items.count
    assert_equal [ BigDecimal("2") ], DeliveryOrder.find(ids.first).delivery_order_items.pluck(:quantity)
    assert_equal snapshot, visit.reload.attributes
    assert_equal 18, item.reload.delivered_quantity
  end

  test "concurrent offline retries commit one operation and one confirmation atomically" do
    order, driver = order_for_execution
    visit = order.visit
    item = visit.delivery_items.first
    attributes = { operation_id: SecureRandom.uuid, visit_id: visit.id, status: "completed", notes: "Offline",
      proof: DriverWorkSnapshot.issue(user: driver, visit: visit), recorded_at: Time.current.iso8601,
      items: [ { id: item.id, delivered_quantity: "18" } ] }
    ids = concurrently { DriverOperationSync.call(user: User.find(driver.id), attributes: attributes).id }
    assert_equal 1, ids.uniq.size
    assert_equal 1, @company.driver_sync_operations.count
    assert_equal "synced", DriverSyncOperation.find(ids.first).status
    assert_equal 18, item.reload.delivered_quantity
    assert_equal driver.id, visit.reload.confirmed_by_id
    assert order.reload.needs_attention?
    assert_raises(ActiveRecord::RecordNotUnique) do
      DriverSyncOperation.transaction(requires_new: true) do
        DriverSyncOperation.insert_all!([ DriverSyncOperation.find(ids.first).attributes.except("id") ])
      end
    end
  end

  test "different device UUIDs racing for one visit preserve one confirmation and one conflict" do
    order, driver = order_for_execution
    visit = order.visit
    item = visit.delivery_items.first
    proof = DriverWorkSnapshot.issue(user: driver, visit: visit)
    results = concurrently do
      DriverOperationSync.call(user: User.find(driver.id), attributes: { operation_id: SecureRandom.uuid, visit_id: visit.id,
        status: "completed", notes: "Otro dispositivo", proof: proof, recorded_at: Time.current.iso8601,
        items: [ { id: item.id, delivered_quantity: 18 } ] }).status
    end
    assert_equal %w[conflict synced], results.sort
    assert_equal 2, @company.driver_sync_operations.count
    assert_equal 18, item.reload.delivered_quantity
    assert_equal driver.id, visit.reload.confirmed_by_id
    assert order.reload.needs_attention?
  end

  test "reassignment racing with confirmation cannot misattribute a visit" do
    order, juan = order_for_execution
    run = order.visit.delivery_run
    visit = order.visit
    item = visit.delivery_items.first
    # Keep the route open whichever request wins the company lock.
    run.visits.create!(customer: @customer, position: 2)
    pedro = @company.users.create!(name: "Pedro", email_address: "pedro-#{@company.id}@example.test", role: :driver, password: "Password-test-2026")
    ready = Queue.new
    start = Queue.new
    work = [
      -> {
        begin
          DriverVisitRecorder.call(user: User.find(juan.id), visit_id: visit.id,
            attributes: { status: "completed", items: [ { id: item.id, delivered_quantity: 18 } ] })
        rescue ActiveRecord::RecordNotFound
          # Reassignment won; Juan's stale screen has no write authority.
        end
      },
      -> { Company.find(@company.id).with_lock { DeliveryRun.find(run.id).update!(driver: pedro) } }
    ]
    threads = work.map do |job|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          job.call
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:value)
    assert_equal pedro.id, run.reload.driver_id
    if visit.reload.pending?
      assert_nil item.reload.delivered_quantity
      DriverVisitRecorder.call(user: pedro, visit_id: visit.id,
        attributes: { status: "completed", items: [ { id: item.id, delivered_quantity: 18 } ] })
      assert_equal pedro.id, visit.reload.confirmed_by_id
    else
      assert_equal juan.id, visit.confirmed_by_id
    end
    assert_equal 18, item.reload.delivered_quantity
    assert_equal 20, item.planned_quantity
  ensure
    threads&.each(&:join)
  end

  test "concurrent optimization requests reuse one active proposal" do
    run, manager = concurrent_optimization_run
    ids = concurrently do
      RouteOptimizationProposal.request!(user: User.find(manager.id), run: DeliveryRun.find(run.id)).id
    end
    assert_equal 1, ids.uniq.size
    assert_equal 1, @company.route_optimization_proposals.count
  end

  test "concurrent automatic confirmations share one publication" do
    run, manager = concurrent_optimization_run
    driver = @company.users.create!(name: "Repartidor", role: :driver, email_address: "publication-driver-#{@company.id}@example.test", password: "Testing-routes-2026")
    run.update!(driver: driver)
    ids = concurrently do
      RoutePublication.request!(user: User.find(manager.id), run: DeliveryRun.find(run.id)).id
    end
    assert_equal 1, ids.uniq.size
    assert_equal 1, @company.route_publications.count
    assert_equal "pending", @company.route_publications.sole.state
  end

  test "concurrent road matrix requests compute one shared tenant cache entry" do
    calculations = Queue.new
    results = concurrently do
      RoutingCacheEntry.fetch(company: Company.find(@company.id), kind: "matrix", key: "a" * 64) do
        calculations << true
        { durations: [ [ 0, 123 ], [ 456, 0 ] ] }
      end
    end
    assert_equal 1, calculations.size
    assert_equal results.first, results.last
    assert_equal 1, @company.routing_cache_entries.count
  end

  test "incompatible optimization applications serialize and the stale one cannot overwrite the winner" do
    run, manager = concurrent_optimization_run
    original = run.visits.pluck(:id)
    first = RouteOptimizationProposal.request!(user: manager, run: run, settings: { departure: "08:00" })
    second = RouteOptimizationProposal.request!(user: manager, run: run, settings: { departure: "09:00" })
    first.update!(status: "ready", result: { proposed: { feasible: true, visit_ids: original.reverse } })
    second.update!(status: "ready", result: { proposed: { feasible: true, visit_ids: original.rotate } })
    work = Queue.new
    [ first.id, second.id ].each { |id| work << id }
    outcomes = concurrently do
      begin
        RouteOptimizationProposal.find(work.pop).apply!(user: User.find(manager.id))
        :applied
      rescue ArgumentError
        :stale
      end
    end
    assert_equal [ :applied, :stale ], outcomes.sort
    assert_equal 1, @company.route_optimization_proposals.where(status: "applied").count
    assert_equal @company.route_optimization_proposals.find_by!(status: "applied").result.dig("proposed", "visit_ids"), run.visits.pluck(:id)
  end

  test "coordinates and legacy delivery windows cannot change between validation and application" do
    run, manager = concurrent_optimization_run
    schedule = @company.delivery_schedules.create!(customer: @customer, weekday: 1, starts_on: @company.local_date, window_start: "08:00", window_end: "09:00")
    run.visits.first.update_columns(delivery_schedule_id: schedule.id)
    proposal = RouteOptimizationProposal.request!(user: manager, run: run)
    proposal.update!(status: "ready", result: { proposed: { feasible: true, visit_ids: run.visits.pluck(:id).reverse } })
    entered, release = Queue.new, Queue.new
    original = DeliveryRunReorderer.method(:call)
    DeliveryRunReorderer.define_singleton_method(:call) do |**options|
      entered << true
      release.pop
      original.call(**options)
    end
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        RouteOptimizationProposal.find(proposal.id).apply!(user: User.find(manager.id))
      end
    end
    Timeout.timeout(30) { entered.pop }
    [ [ @customer, { latitude: -34.7 } ], [ schedule, { window_end: "10:00" } ] ].each do |record, attributes|
      assert_raises(ActiveRecord::LockWaitTimeout) do
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '100ms'")
          record.update_columns(attributes)
        end
      end
    end
    release << true
    thread.value
    assert_equal "applied", proposal.reload.status
  ensure
    release << true if release && thread&.alive?
    thread&.join
    DeliveryRunReorderer.define_singleton_method(:call, original) if original
  end

  private


  def concurrent_optimization_run
    @customer.update!(latitude: -34.8, longitude: -58.39)
    manager = @company.users.create!(name: "Administrador", role: :administrator, email_address: "route-manager-#{@company.id}@example.test", password: "Testing-routes-2026")
    run = @company.delivery_runs.create!(name: "Concurrent route", scheduled_date: @company.local_date)
    3.times { |index| run.visits.create!(company: @company, customer: @customer, position: index + 1) }
    [ run, manager ]
  end

  def order_for_execution
    driver = @company.users.create!(name: "Juan", email_address: "juan-#{@company.id}@example.test", role: :driver, password: "Password-test-2026")
    order = @company.delivery_orders.create!(customer: @customer, scheduled_date: @company.local_date,
      delivery_order_items_attributes: [ { description: "Pan", unit: "pack", quantity: 20 } ])
    run = @company.delivery_runs.new(name: "Concurrente", scheduled_date: order.scheduled_date, driver: driver, status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: run, order_ids: [ order.id ])
    [ order.reload, driver ]
  end

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
