require "test_helper"

class VisitCheckpointTest < ActiveSupport::TestCase
  setup do
    @company = companies(:one)
    @user = users(:driver)
    @order = @company.delivery_orders.create!(customer: customers(:one), scheduled_date: @company.local_date,
      delivery_order_items_attributes: [ { description: "Pan", unit: "pack", quantity: 10 } ])
    @run = @company.delivery_runs.new(name: "Tiempos reales", scheduled_date: @company.local_date, driver: @user, status: :assigned)
    DeliveryRunPlanner.call(company: @company, delivery_run: @run, order_ids: [ @order.id ])
    @visit = @order.reload.visit
    @proof = DriverWorkSnapshot.issue(user: @user, visit: @visit)
  end

  def checkpoint(stage, at: Time.current, id: SecureRandom.uuid)
    DriverOperationSync.call(user: @user, attributes: { operation_id: id, operation_type: "visit_checkpoint", visit_id: @visit.id,
      checkpoint: stage, occurred_at: at.iso8601(3), recorded_at: at.iso8601(3), proof: @proof, status: "pending", items: [] })
  end

  test "three offline checkpoints and final receipt are independent durable and idempotent" do
    started = Time.current.change(usec: 0)
    id = SecureRandom.uuid
    arrival = checkpoint("arrived_at", at: started, id: id)
    assert arrival.status_synced?
    assert_equal arrival, checkpoint("arrived_at", at: started, id: id)
    assert_equal started, @visit.reload.arrived_at
    assert @visit.pending?
    assert_not @visit.plannable?
    assert_not @visit.destroy
    assert @run.reload.in_progress?
    plan = DriverWorkSnapshot.revision(@visit)
    package = DriverWorkSnapshot.package_revision(run: @run, runs: [ @run ], visits: [ @visit ], date: @company.local_date)
    assert checkpoint("unloading_started_at", at: started + 1.minute).status_synced?
    assert_equal plan, DriverWorkSnapshot.revision(@visit.reload)
    assert_not_equal package, DriverWorkSnapshot.package_revision(run: @run, runs: [ @run ], visits: [ @visit ], date: @company.local_date)
    assert checkpoint("unloading_finished_at", at: started + 3.minutes).status_synced?
    assert_equal 120, @visit.reload.unloading_seconds
    final = DriverOperationSync.call(user: @user, attributes: { operation_id: SecureRandom.uuid, visit_id: @visit.id, proof: @proof,
      status: "completed", recorded_at: (started + 4.minutes).iso8601, items: [ { id: @visit.delivery_items.first.id, delivered_quantity: "10" } ] })
    assert final.status_synced?
    assert @order.reload.fully_delivered?
    assert_equal 4, @company.driver_sync_operations.count
    event = @company.delivery_status_events.where(visit_id: @visit.id, to_status: "completed").sole
    assert_equal @user.id, event.user_id
    assert_equal "offline", event.source
    assert_equal final.operation_id, event.operation_id
    assert_equal 1, @run.run_stock_movements.count
    assert_not @visit.update(arrived_at: started + 1.second)
  end

  test "out of order future and stale assignment checkpoints remain auditable without changing the visit" do
    invalid = checkpoint("unloading_started_at")
    assert invalid.status_invalid?
    assert_nil @visit.reload.unloading_started_at
    assert checkpoint("arrived_at", at: 10.minutes.from_now).status_invalid?
    assert checkpoint("destroy!").status_invalid?
    @run.update!(driver: nil, status: :draft)
    conflict = checkpoint("arrived_at")
    assert conflict.status_conflict?
    assert_nil @visit.reload.arrived_at
  end

  test "legacy v2 authorization remains valid after new columns and real timing captures" do
    legacy = DriverWorkSnapshot.verifier.generate({ "company_id" => @company.id, "user_id" => @user.id, "visit_id" => @visit.id,
      "revision" => DriverWorkSnapshot.revision(@visit, version: 2), "issued_at" => Time.current.to_i, "expires_at" => 1.hour.from_now.to_i,
      "snapshot" => DriverWorkSnapshot.snapshot(@visit) }, purpose: DriverWorkSnapshot::PURPOSE)
    assert checkpoint("arrived_at").status_synced?
    result = DriverOperationSync.call(user: @user, attributes: { operation_id: SecureRandom.uuid, visit_id: @visit.id, proof: legacy,
      status: "closed", notes: "Cerrado", recorded_at: Time.current.iso8601, items: [] })
    assert result.status_synced?
    assert @order.reload.closed?
    assert_not @order.fully_delivered?
  end
end
