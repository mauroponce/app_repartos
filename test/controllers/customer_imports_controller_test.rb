require "test_helper"
require "tempfile"
require_relative "../test_helpers/customer_import_test_helper"

class CustomerImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include CustomerImportTestHelper
  setup { sign_in_as users(:one) }

  test "upload map review manual correction and asynchronous confirmation complete the wizard" do
    get customers_path
    assert_select "a[href=?]", new_customer_import_path, text: "Importar clientes"
    get template_customer_imports_path
    assert_response :success
    Tempfile.create([ "customers", ".csv" ]) do |file|
      file.write("Identificador;Comercio;Calle;Zona\n0001;Local;Mitre 1;CABA\n")
      file.flush
      assert_no_difference "Customer.count" do
        post customer_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv"), company_id: companies(:two).id }
      end
    end
    import = companies(:one).customer_imports.last
    assert_equal "reading", import.state
    assert_equal users(:one), import.initiated_by
    perform_enqueued_jobs(only: CustomerImportJob)
    assert_equal "mapping", import.reload.state
    patch customer_import_path(import), params: { mapping: { external_code: "0", name: "1", address: "2", city: "3", company_id: "4" }, geographic_context: { province: "Buenos Aires", company_id: companies(:two).id } }
    assert_redirected_to customer_import_path(import)
    assert_not import.reload.mapping.key?("company_id")
    assert_not import.geographic_context.key?("company_id")
    post start_customer_import_path(import)
    offline_providers { drain_import_jobs }
    assert_equal "review", import.reload.state
    get customer_import_path(import)
    assert_response :success
    assert_select "h2", text: "3. Revisar resultados"
    row = import.import_rows.first
    get edit_customer_import_row_path(import, row)
    assert_response :success
    assert_select "div[data-location-target=map]"
    patch customer_import_row_path(import, row), params: { row: { name: "Local", address: "Mitre 1", city: "Adrogué", latitude: -34.80, longitude: -58.39 }, decision: "manual" }
    assert row.reload.manual_confirmation?
    post confirm_customer_import_path(import), params: { acknowledge_duplicates: "1", acknowledge_pending: "1" }
    assert_equal "importing", import.reload.state
    assert_difference "Customer.count", 1 do
      perform_enqueued_jobs(only: CustomerImportJob)
    end
    get customer_import_path(import)
    assert_select "h2", text: "Importación confirmada"
    assert_no_difference "Customer.count" do
      post confirm_customer_import_path(import)
      perform_enqueued_jobs(only: CustomerImportJob)
    end
    assert_equal "manual", Customer.find_by!(external_code: "0001").location_verification
    get errors_customer_import_path(import)
    assert_match "attachment", response.headers["Content-Disposition"]
  end

  test "foreign imports all actions and driver access are denied" do
    import = companies(:two).customer_imports.create!(state: "review")
    row = import.import_rows.create!(company: companies(:two), number: 2)
    [ customer_import_path(import), errors_customer_import_path(import), edit_customer_import_row_path(import, row) ].each do |path|
      get path
      assert_response :not_found
    end
    [ start_customer_import_path(import), cancel_customer_import_path(import), resume_customer_import_path(import), confirm_customer_import_path(import) ].each do |path|
      post path
      assert_response :not_found
    end
    patch customer_import_path(import), params: { mapping: { name: "0" } }
    assert_response :not_found
    patch customer_import_row_path(import, row), params: { decision: "exclude" }
    assert_response :not_found
    sign_in_as users(:driver)
    get new_customer_import_path
    assert_response :forbidden
    post customer_imports_path
    assert_response :forbidden
  end

  test "supervisors may import and internal errors are escaped in CSV export" do
    sign_in_as users(:supervisor)
    get new_customer_import_path
    assert_response :success
    import = smart_import
    import.import_rows.first.update!(issues: [ "=HYPERLINK(\"evil\")" ])
    get errors_customer_import_path(import)
    assert_response :success
    assert_includes response.body, "'=HYPERLINK"
  end

  test "rows cannot be edited during processing and an unresolved row can be kept without location" do
    import = smart_import
    row = import.import_rows.first
    patch customer_import_row_path(import, row), params: { decision: "exclude" }
    assert_not row.reload.excluded?
    prepare_smart_import(import)
    patch customer_import_row_path(import, row), params: { row: { name: "Corregido", address: "Belgrano 450", city: "Adrogué" }, decision: "unlocated" }
    assert_equal "unlocated", row.reload.review_state
    assert_nil row.latitude
    assert_empty row.issues
    import.update!(state: "importing")
    patch customer_import_row_path(import, row), params: { decision: "exclude" }
    assert_not row.reload.excluded?
  end
  test "manual review rejects points outside the company province even if they are in Argentina" do
    import = smart_import
    prepare_smart_import(import)
    row = import.import_rows.first
    patch customer_import_row_path(import, row), params: { row: { name: "Prueba", address: "Belgrano 450", city: "Adrogué", latitude: -34.60, longitude: -58.38 }, decision: "manual" }
    assert_not row.reload.manual_confirmation?
    assert_nil row.latitude
    assert_redirected_to edit_customer_import_row_path(import, row)
    assert_includes flash[:alert], "Buenos Aires"
  end

  test "company province belongs to the session and only administrators can configure it" do
    get edit_company_settings_path
    assert_response :success
    patch company_settings_path, params: { company: { province: "Córdoba", id: companies(:two).id } }
    assert_equal "Córdoba", companies(:one).reload.province
    assert_equal "Buenos Aires", companies(:two).reload.province
    smart_import
    patch company_settings_path, params: { company: { province: "Buenos Aires" } }
    assert_response :unprocessable_entity
    assert_equal "Córdoba", companies(:one).reload.province
    sign_in_as users(:supervisor)
    get edit_company_settings_path
    assert_response :forbidden
  end
end
