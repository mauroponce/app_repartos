require "test_helper"

class DriverSyncControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = companies(:one)
    @driver = users(:driver)
    @order = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @company.local_date,
      delivery_order_items_attributes: [ { description: "Pan", unit: "pack", quantity: 20 }, { description: "Aceite", unit: "l", quantity: "2.500" } ])
    @run = @company.delivery_runs.new(name: "Offline", scheduled_date: @order.scheduled_date, driver: @driver, status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ @order.id ])
    @visit = @order.reload.visit
    sign_in_as @driver
  end

  test "download is versioned private scoped and contains no persisted credentials in its presentation" do
    get "/repartidor/api/v1/work"
    assert_response :success
    data = response.parsed_body
    assert_equal 4, data["version"]
    assert_equal({ "company_id" => @company.id, "user_id" => @driver.id }, data["account"])
    assert data["csrf_token"].present?
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal [ @run.id ], data["packages"].map { |pack| pack["id"] }
    visit = data["packages"].first["visits"].first
    assert_equal @visit.id, visit["id"]
    assert_equal [ "20.0", "2.5" ], visit["items"].map { |item| item["planned_quantity"] }
    assert DriverWorkSnapshot.read(visit["proof"])
    assert_no_match(/authenticity_token|csrf-token/, data["packages"].first["html"])
    assert_no_match customers(:other_company).name, response.body
  end

  test "full partial and zero deliveries reuse fulfillment rules and server confirmation authorship" do
    [ [ 20, "2.500", "completed", "full" ], [ 18, "2.125", "needs_attention", "partial" ], [ 0, 0, "needs_attention", "none" ] ].each do |first, second, status, result|
      # Roll each scenario back so it starts with the same pending visit.
      ApplicationRecord.transaction(requires_new: true) do
        operation = attributes(quantities: [ first, second ])
        submit(operation)
        assert_response :success
        assert_equal "synced", response.parsed_body["status"]
        assert_equal status, @order.reload.status
        assert_equal result, @order.fulfillment_result
        assert_equal @driver.id, @visit.reload.confirmed_by_id
        assert_in_delta Time.current, @visit.confirmed_at, 5
        assert_equal [ BigDecimal("20"), BigDecimal("2.5") ], @visit.delivery_items.order(:id).pluck(:planned_quantity)
        raise ActiveRecord::Rollback
      end
      @visit.reload
    end
  end

  test "failed visit is synced with zero quantities and an immutable incident" do
    submit(attributes.merge(status: "not_attended", notes: "No atendió"))
    assert_response :success
    assert_equal "synced", response.parsed_body["status"]
    assert_equal "not_attended", @visit.reload.status
    assert_equal [ 0, 0 ], @visit.delivery_items.pluck(:delivered_quantity)
    assert @order.reload.needs_attention?
  end

  test "duplicate UUID returns original receipt without writing execution twice even after midnight" do
    operation = attributes
    submit(operation)
    receipt = response.parsed_body
    snapshot = @visit.reload.attributes
    travel 1.day do
      assert_no_difference "DriverSyncOperation.count" do
        submit(operation)
        assert_equal receipt, response.parsed_body
      end
    end
    assert_equal snapshot, @visit.reload.attributes
    get "/repartidor/api/v1/operations/#{operation[:operation_id]}"
    assert_equal receipt, response.parsed_body
    submit(operation.merge(notes: "Different content"))
    assert_response :conflict
    assert_equal snapshot, @visit.reload.attributes
  end

  test "midnight does not invalidate a downloaded route or use the device timestamp as authorization" do
    Time.use_zone(@company.time_zone) do
      travel_to @company.local_date.end_of_day - 10.minutes do
        operation = attributes.merge(recorded_at: "2099-12-31T23:59:00Z")
        travel 20.minutes
        submit(operation)
        assert_response :success
        assert_equal "synced", response.parsed_body["status"]
        assert_in_delta Time.current, @visit.reload.confirmed_at, 5
      end
    end
  end

  test "expired server grant is a retained conflict even if the phone claims an earlier timestamp" do
    operation = attributes
    travel 49.hours do
      submit(operation)
      assert_equal "conflict", response.parsed_body["status"]
    end
    assert @visit.reload.pending?
    assert_nil @visit.confirmed_by_id
    assert_equal operation[:notes], @driver.driver_sync_operations.last.payload["notes"]
  end

  test "reassignment and assignment away then back invalidate the original grant" do
    operation = attributes
    @run.update!(driver: users(:inactive_driver).tap { |driver| driver.update!(status: :active) })
    @run.update!(driver: @driver)
    submit(operation)
    assert_equal "conflict", response.parsed_body["status"]
    assert @visit.reload.pending?
  end

  test "planning changes and recording on another device produce conflicts without overwrites" do
    operation = attributes
    item = @order.delivery_order_items.first
    DeliveryOrderEditor.call(order: @order, attributes: { delivery_order_items_attributes: [ { id: item.id, quantity: 25 } ] })
    submit(operation)
    assert_equal "conflict", response.parsed_body["status"]
    original = @driver.driver_sync_operations.last.payload.fetch("download_snapshot")
    assert_equal "20.0", original["items"].first["planned_quantity"]
    assert_nil @visit.delivery_items.first.reload.delivered_quantity
    fresh = attributes
    DriverVisitRecorder.call(user: @driver, visit_id: @visit.id, attributes: { status: "closed", notes: "Otro dispositivo" })
    snapshot = @visit.reload.attributes
    submit(fresh)
    assert_equal "conflict", response.parsed_body["status"]
    assert_equal snapshot, @visit.reload.attributes
  end

  test "validation errors are durable and roll back all quantities" do
    operation = attributes(quantities: [ 18, -1 ])
    submit(operation)
    assert_response :success
    assert_equal "invalid", response.parsed_body["status"]
    assert @visit.reload.pending?
    assert_equal [ nil, nil ], @visit.delivery_items.pluck(:delivered_quantity)
    assert_nil @visit.confirmed_at
    assert @order.reload.pending?
    assert_no_difference "DriverSyncOperation.count" do
      submit(operation)
      assert_equal "invalid", response.parsed_body["status"]
    end
  end

  test "revoked sessions and foreign users cannot upload or inspect operations" do
    operation = attributes
    submit(operation)
    id = response.parsed_body["operation_id"]
    sign_in_as users(:other_driver)
    submit(operation)
    assert_response :forbidden
    get "/repartidor/api/v1/operations/#{id}"
    assert_response :not_found
    sign_in_as @driver
    @driver.sessions.destroy_all
    submit(operation)
    assert_response :unauthorized
    get "/repartidor/api/v1/work"
    assert_response :unauthorized
  end

  test "administration can inspect retained conflicts only within its company" do
    operation = attributes
    @visit.update!(status: :closed, confirmed_by: users(:one))
    submit(operation)
    record = @driver.driver_sync_operations.last
    assert record.status_conflict?
    sign_in_as users(:one)
    get driver_sync_operations_path
    assert_response :success
    get driver_sync_operation_path(record)
    assert_response :success
    assert_match operation[:notes], response.body
    sign_in_as users(:two)
    get driver_sync_operation_path(record)
    assert_response :not_found
    sign_in_as @driver
    get driver_sync_operations_path
    assert_response :forbidden
  end

  test "public shell and worker contain only public content and no tracking" do
    get repartidor_shell_path
    assert_response :success
    assert_no_match @driver.name, response.body
    assert_no_match @company.name, response.body
    assert_no_match(/csrf-token|authenticity_token/, response.body)
    get repartidor_service_worker_path
    assert_response :success
    assert_match "/assets/offline/store-", response.body
    assert_no_match "tile.openstreetmap", response.body
    assert_no_match "deleteDatabase", response.body
  end

  test "download excludes other drivers other tenants drafts and future routes" do
    colleague = @company.users.create!(name: "Otro", email_address: "offline-colleague@example.test", role: :driver, password: "Offline-test-2026")
    [ [ @company, colleague, @company.local_date, :assigned ], [ companies(:two), users(:other_driver), @company.local_date, :assigned ],
      [ @company, @driver, @company.local_date, :draft ], [ @company, @driver, @company.local_date + 1, :assigned ] ].each do |company, driver, date, status|
      company.delivery_runs.create!(name: "No descargar", scheduled_date: date, driver: driver, status: status)
    end
    get "/repartidor/api/v1/work"
    assert_response :success
    assert_equal [ @run.id ], response.parsed_body["packages"].map { |pack| pack["id"] }
    assert_no_match "No descargar", response.body
  end

  test "a cancelled route retains the attempted operation without writing a visit" do
    run = @company.delivery_runs.create!(name: "Manual cancelada", scheduled_date: @company.local_date, driver: @driver, status: :assigned)
    visit = run.visits.create!(customer: customers(:one), position: 1)
    item = visit.delivery_items.create!(description: "Manual", unit: "box", planned_quantity: 2)
    operation = attributes.merge(visit_id: visit.id, proof: DriverWorkSnapshot.issue(user: @driver, visit: visit), items: [ { id: item.id, delivered_quantity: 2 } ])
    run.update!(status: :cancelled)
    submit(operation)
    assert_equal "conflict", response.parsed_body["status"]
    assert visit.reload.pending?
    assert_nil item.reload.delivered_quantity
  end

  test "failure persisting the receipt rolls back every business effect" do
    operation = attributes
    DriverSyncOperation.before_create :abort_sync_test
    DriverSyncOperation.define_method(:abort_sync_test) { throw :abort }
    assert_no_difference "DriverSyncOperation.count" do
      assert_raises(ActiveRecord::RecordNotSaved) { DriverOperationSync.call(user: @driver, attributes: operation) }
    end
    assert @visit.reload.pending?
    assert_nil @visit.confirmed_by_id
    assert_equal [ nil, nil ], @visit.delivery_items.pluck(:delivered_quantity)
    assert @order.reload.pending?
  ensure
    DriverSyncOperation.skip_callback(:create, :before, :abort_sync_test)
    DriverSyncOperation.remove_method(:abort_sync_test)
  end

  private

  def attributes(quantities: [ 18, "2.125" ])
    { operation_id: SecureRandom.uuid, visit_id: @visit.id, status: "completed", notes: "Recibió María",
      recorded_at: Time.current.iso8601, proof: DriverWorkSnapshot.issue(user: @driver, visit: @visit.reload),
      items: @visit.delivery_items.order(:id).zip(quantities).map { |item, quantity| { id: item.id, delivered_quantity: quantity } } }
  end

  def submit(operation)
    post "/repartidor/api/v1/operations", params: { operation: operation }, as: :json
  end
end
