require "test_helper"
require "tempfile"

class OperationImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { sign_in_as users(:one) }

  test "management can upload and get the template without creating data synchronously" do
    get new_operation_import_path
    assert_response :success
    get template_operation_imports_path
    assert_response :success
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", response.media_type
    Tempfile.create([ "operation", ".csv" ]) do |file|
      file.write(OperationImports::Reader::HEADERS.join(",") + "\nAna,Kiosco,visita_semanal,,lunes,,,Burzaco,Uno 123,,,,,\n")
      file.flush
      assert_difference "companies(:one).operation_imports.count", 1 do
        post operation_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv") }
      end
      assert_no_difference "companies(:one).operation_imports.count" do
        post operation_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv") }
      end
    end
    batch = companies(:one).operation_imports.last
    assert_equal "reading", batch.state
    perform_enqueued_jobs(only: OperationImportJob)
    OperationImportJob.perform_now(batch.company_id, batch.id, "analyze") if batch.reload.state == "analyzing"
    assert_equal "review", batch.reload.state
    get operation_import_path(batch)
    assert_response :success
    post confirm_operation_import_path(batch)
    perform_enqueued_jobs(only: OperationImportJob)
    OperationImportJob.perform_now(batch.company_id, batch.id, "commit") if batch.reload.state == "importing"
    assert_equal "finished", batch.reload.state
    row = batch.rows.first
    patch operation_import_row_path(batch, row), params: { row: row.original.merge("cliente" => "Otro") }
    assert_redirected_to operation_import_path(batch)
    assert_equal "Kiosco", row.reload.original["cliente"]
  end

  test "foreign imports and driver access are denied" do
    batch = companies(:two).operation_imports.create!(sha256: SecureRandom.hex(32))
    get operation_import_path(batch)
    assert_response :not_found
    post confirm_operation_import_path(batch)
    assert_response :not_found
    sign_in_as users(:driver)
    get new_operation_import_path
    assert_response :forbidden
    post operation_imports_path
    assert_response :forbidden
  end

  test "exceptions appear before many valid groups" do
    batch = companies(:one).operation_imports.create!(sha256: SecureRandom.hex(32), state: "review")
    51.times do |index|
      batch.groups.create!(company: batch.company, group_key: "valid-#{index}", state: "ready", data: { "cliente" => "Válido #{index}" })
    end
    batch.groups.create!(company: batch.company, group_key: "problem", state: "review", data: { "cliente" => "Revisar" }, issues: [ "Ambiguo" ])
    get operation_import_path(batch)
    assert_response :success
    assert_select "article h3:first", text: /Revisar/
    assert_select "a[href='#{operation_import_path(batch, state: 'review')}']", text: /review \(1\)/
  end

  test "correcting one ambiguous row separates its order reference" do
    row = "Ana,Kiosco,pedido_puntual,2026-11-25,,09:00,10:00,Burzaco,Uno 123,Pan,2,,,"
    Tempfile.create([ "operation", ".csv" ]) do |file|
      file.write(OperationImports::Reader::HEADERS.join(",") + "\n#{row}\n#{row}\n")
      file.flush
      post operation_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv") }
    end
    batch = companies(:one).operation_imports.last
    OperationImportJob.perform_now(batch.company_id, batch.id, "read")
    OperationImportJob.perform_now(batch.company_id, batch.id, "analyze")
    assert_equal "review", batch.groups.first.state
    source = batch.rows.order(:number).last
    patch operation_import_row_path(batch, source), params: { row: source.original.merge("referencia_pedido" => "SEGUNDO") }
    assert_redirected_to operation_import_path(batch)
    OperationImportJob.perform_now(batch.company_id, batch.id, "analyze")
    assert_equal 2, batch.groups.count
    assert_equal 2, batch.groups.where(state: "ready").count
  end

  test "an ambiguous product can be selected for one source row" do
    product = companies(:one).products.create!(name: "Pan", unit: "unit")
    companies(:one).products.create!(name: "PAN", unit: "unit")
    Tempfile.create([ "operation", ".csv" ]) do |file|
      file.write(OperationImports::Reader::HEADERS.join(",") + "\nAna,Kiosco,pedido_puntual,2026-11-25,,,,Burzaco,Uno 123,Pan,2,,,\n")
      file.flush
      post operation_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv") }
    end
    batch = companies(:one).operation_imports.last
    OperationImportJob.perform_now(batch.company_id, batch.id, "read")
    OperationImportJob.perform_now(batch.company_id, batch.id, "analyze")
    assert_equal "review", batch.groups.first.state
    assert_match(/Producto ambiguo/, batch.groups.first.issues.join)
    patch operation_import_group_path(batch, batch.groups.first), params: { decision: "create", cliente: "Kiosco", calle: "Uno 123", localidad: "Burzaco", repartidor: "Ana" }
    assert_equal "review", batch.groups.first.reload.state

    source = batch.rows.first
    patch operation_import_row_path(batch, source), params: { row: source.original.merge("product_id" => product.id) }
    assert_redirected_to operation_import_path(batch)
    OperationImportJob.perform_now(batch.company_id, batch.id, "analyze")
    assert_equal "ready", batch.groups.first.state
    patch operation_import_group_path(batch, batch.groups.first), params: { decision: "create", cliente: "KIOSCO", calle: "Uno 123", localidad: "Burzaco", repartidor: "Ana" }
    assert_equal product.id, source.reload.data["product_id"]
    post confirm_operation_import_path(batch)
    OperationImportJob.perform_now(batch.company_id, batch.id, "commit")
    assert_equal product, companies(:one).delivery_orders.find_by!(import_key: batch.groups.first.group_key).delivery_order_items.first.product
  end

  test "an inactive matching product can be replaced by a new catalog entry" do
    companies(:one).products.create!(name: "Pan", unit: "unit", active: false)
    Tempfile.create([ "operation", ".csv" ]) do |file|
      file.write(OperationImports::Reader::HEADERS.join(",") + "\nAna,Kiosco,pedido_puntual,2026-11-25,,,,Burzaco,Uno 123,Pan,2,,,\n")
      file.flush
      post operation_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv") }
    end
    batch = companies(:one).operation_imports.last
    OperationImportJob.perform_now(batch.company_id, batch.id, "read")
    OperationImportJob.perform_now(batch.company_id, batch.id, "analyze")
    assert_equal "review", batch.groups.first.state
    source = batch.rows.first
    patch operation_import_row_path(batch, source), params: { row: source.original.merge("new_product" => "1") }
    OperationImportJob.perform_now(batch.company_id, batch.id, "analyze")
    assert_equal "ready", batch.groups.first.state
    post confirm_operation_import_path(batch)
    OperationImportJob.perform_now(batch.company_id, batch.id, "commit")
    assert_equal 2, companies(:one).products.where(name_key: "pan").count
    assert companies(:one).delivery_orders.find_by!(import_key: batch.groups.first.group_key).delivery_order_items.first.product.active?
  end
end
