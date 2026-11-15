require "test_helper"
require_relative "../test_helpers/single_route_test_helper"
require_relative "../test_helpers/delivery_evidence_test_helper"

class CommercialPilotTest < ActionDispatch::IntegrationTest
  include SingleRouteTestHelper
  include DeliveryEvidenceTestHelper

  setup do
    @company, @driver = companies(:one), users(:driver)
    @evidence_files, @evidence_blobs = [], []
    sign_in_as users(:one)
  end
  teardown { clean_evidence_files }

  test "Excel onboarding route planning road preview offline receipt evidence incident and administration stay tenant scoped" do
    post customer_imports_path, params: { file: fixture_file_upload("customers.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") }
    import = @company.customer_imports.last
    get customer_import_path(import)
    digest = css_select('input[name="preview_digest"]').first["value"]
    post confirm_customer_import_path(import), params: { preview_digest: digest }
    assert_redirected_to customer_import_path(import)
    customer = @company.customers.find_by!(external_code: "000123")
    assert_nil customer.phone
    assert_not customer.located?
    patch customer_path(customer), params: { customer: { latitude: -34.6037, longitude: -58.3816 } }
    assert_redirected_to customer_path(customer)
    assert customer.reload.located?

    post products_path, params: { product: { name: "Producto del piloto", sku: "PILOT-01", unit: "box" } }
    assert_redirected_to products_path
    product = @company.products.find_by!(sku: "PILOT-01")
    orders = [ customer, customers(:one) ].map do |destination|
      post delivery_orders_path, params: { delivery_order: { customer_id: destination.id, scheduled_date: @company.local_date,
        delivery_order_items_attributes: [ { product_id: product.id, quantity: 4 } ] } }
      assert response.redirect?
      @company.delivery_orders.order(:id).last
    end
    post delivery_runs_path, params: { delivery_run: { name: "Piloto integrado", scheduled_date: @company.local_date, driver_id: @driver.id, status: "assigned" }, order_ids: orders.map(&:id) }
    assert response.redirect?
    run = @company.delivery_runs.find_by!(name: "Piloto integrado")
    assert_equal 2, run.visits.count
    post delivery_run_optimization_proposals_path(run)
    proposal = run.route_optimization_proposals.last
    with_single_client { OptimizeDeliveryRunJob.perform_now(@company.id, proposal.id) }
    assert_equal "ready", proposal.reload.status
    post apply_delivery_run_optimization_proposal_path(run, proposal)
    assert_redirected_to delivery_run_path(run)
    assert_equal "applied", proposal.reload.status

    sign_in_as @driver
    get "/repartidor/api/v1/work"
    assert_response :success
    pack = response.parsed_body["packages"].find { |row| row["id"] == run.id }
    grant = pack["visits"].find { |row| row["id"] == orders.first.reload.visit_id }
    @visit = @company.visits.find(grant.fetch("id"))
    @proof, @operation_id = grant.fetch("proof"), SecureRandom.uuid
    evidences = %w[photo signature].map do |kind|
      post "/repartidor/api/v1/evidences", params: { evidence: evidence_upload(kind: kind) }
      assert_response :success
      evidence = @company.delivery_evidences.find_by!(evidence_uuid: response.parsed_body.fetch("id"))
      @evidence_blobs << evidence.file.blob
      evidence
    end
    # The payload represents a durable offline operation. IndexedDB/browser
    # restart and loss-of-network behavior are exercised by the browser suite.
    operation = proof_operation(evidences: evidences, failure_reason: "shortage", items: grant["items"].map { |item| { id: item["id"], delivered_quantity: "3" } })
    2.times do
      post "/repartidor/api/v1/operations", params: { operation: operation }, as: :json
      assert_response :success
      assert_equal "synced", response.parsed_body["status"]
      assert_equal evidences.map(&:evidence_uuid).sort, response.parsed_body.dig("result", "evidence_ids").sort
    end
    assert_equal 1, @company.driver_sync_operations.where(operation_id: @operation_id).count
    assert_equal "needs_attention", orders.first.reload.status
    assert_equal "partial", orders.first.fulfillment_result
    assert_equal @driver.id, @visit.reload.confirmed_by_id
    assert_equal 1, @company.incidents.where(visit_id: @visit.id).count

    sign_in_as users(:one)
    get delivery_receipt_path(@visit)
    assert_response :success
    evidences.each do |evidence|
      get delivery_evidence_path(evidence)
      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
    end
    incident = @company.incidents.find_by!(visit_id: @visit.id)
    get incident_path(incident)
    assert_response :success
    get reports_path
    assert_response :success
    assert @company.delivery_status_events.where(user_id: @driver.id).exists?

    sign_in_as users(:two)
    [ customer_path(customer), edit_product_path(product), delivery_order_path(orders.first), driver_path(@driver), delivery_run_path(run), incident_path(incident), customer_import_path(import), delivery_receipt_path(@visit), *evidences.map { |evidence| delivery_evidence_path(evidence) } ].each do |path|
      get path
      assert_response :not_found
    end
    get reports_path
    assert_response :success
    assert_no_match(/Piloto integrado|Producto del piloto/, response.body)
    sign_in_as users(:other_driver)
    get "/repartidor/api/v1/operations/#{@operation_id}"
    assert_response :not_found
    post "/repartidor/api/v1/operations", params: { operation: operation }, as: :json
    assert_response :forbidden
    get "/repartidor/api/v1/work"
    assert_response :success
    assert_not_includes response.parsed_body["packages"].flat_map { |row| row["visits"].pluck("id") }, @visit.id
  end
end
