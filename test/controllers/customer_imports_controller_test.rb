require "test_helper"
require "tempfile"

class CustomerImportsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "upload map review download errors confirm and repeat show a stable summary" do
    get customers_path
    assert_select "a[href=?]", new_customer_import_path, text: "Importar clientes"
    get template_customer_imports_path
    assert_response :success
    assert_includes response.body, "Código externo"
    Tempfile.create([ "customers", ".csv" ]) do |file|
      file.write("Identificador;Comercio;Calle;Zona\n0001;Local;Mitre 1;CABA\n")
      file.flush
      assert_no_difference "Customer.count" do
        post customer_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "text/csv"), company_id: companies(:two).id }
      end
    end
    import = companies(:one).customer_imports.last
    assert_redirected_to customer_import_path(import)
    patch customer_import_path(import), params: { mapping: { external_code: "0", name: "1", address: "2", city: "3", company_id: "4" } }
    assert_redirected_to customer_import_path(import)
    assert_not import.reload.mapping.key?("company_id")
    follow_redirect!
    assert_select "td", text: "Ubicación pendiente"
    digest = css_select('input[name="preview_digest"]').first["value"]
    get errors_customer_import_path(import)
    assert_response :success
    assert_match "attachment", response.headers["Content-Disposition"]
    assert_difference "Customer.count", 1 do
      post confirm_customer_import_path(import), params: { preview_digest: digest }
    end
    follow_redirect!
    assert_select "h2", text: "Importación confirmada"
    assert_no_difference "Customer.count" do
      post confirm_customer_import_path(import), params: { preview_digest: digest }
    end
    assert_equal companies(:one), Customer.find_by!(external_code: "0001").company
  end

  test "foreign imports all actions and driver access are denied" do
    import = companies(:two).customer_imports.create!(headers: %w[nombre], rows: [ [ "Privado" ] ], mapping: { name: "0" })
    get customer_import_path(import)
    assert_response :not_found
    get errors_customer_import_path(import)
    assert_response :not_found
    patch customer_import_path(import), params: { mapping: { name: "0" } }
    assert_response :not_found
    post confirm_customer_import_path(import)
    assert_response :not_found
    sign_in_as users(:driver)
    get new_customer_import_path
    assert_response :forbidden
    post customer_imports_path
    assert_response :forbidden
  end
end
