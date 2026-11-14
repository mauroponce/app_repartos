require "test_helper"
require "tempfile"

class ProductImportsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "upload preview mapping and confirmation import CSV without premature writes" do
    get new_product_import_path
    assert_response :success
    get template_product_imports_path
    assert_response :success
    assert_includes response.body, ProductImporter::FIELDS.join(",")
    with_csv("Código;Descripción;Medida\nCSV-01;Especial;kg\n") do |upload|
      assert_no_difference "Product.count" do
        post product_imports_path, params: { file: upload, company_id: companies(:two).id }
      end
    end
    import = companies(:one).product_imports.last
    assert_redirected_to product_import_path(import)
    follow_redirect!
    assert_select "input[type=submit][value='Confirmar importación'][disabled]"
    patch product_import_path(import), params: { mapping: { sku: "0", name: "1", unit: "2", company_id: companies(:two).id.to_s } }
    assert_redirected_to product_import_path(import)
    assert_not import.reload.mapping.key?("company_id")
    follow_redirect!
    assert_select "input[type=submit][value='Confirmar importación']:not([disabled])"
    assert_difference "companies(:one).products.count", 1 do
      post confirm_product_import_path(import)
    end
    assert_redirected_to products_path
    assert_no_difference "Product.count" do
      post confirm_product_import_path(import)
    end
    assert_equal companies(:one), Product.find_by!(sku: "CSV-01").company
  end

  test "XLSX upload previews rows and confirmation persists them" do
    post product_imports_path, params: { file: fixture_file_upload("products.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") }
    import = companies(:one).product_imports.last
    assert_redirected_to product_import_path(import)
    follow_redirect!
    assert_select "td", text: "XLS-01"
    assert_difference "Product.count", 2 do
      post confirm_product_import_path(import)
    end
    assert_redirected_to products_path
  end

  test "bad upload invalid rows and missing SKU confirmation produce actionable feedback" do
    post product_imports_path
    assert_response :unprocessable_entity
    with_csv("name,unit\nValid,kg\nInvalid,pallet\n") { |upload| post product_imports_path, params: { file: upload } }
    import = companies(:one).product_imports.last
    follow_redirect!
    assert_select ".import-errors", text: /Fila 3/
    assert_no_difference "Product.count" do
      post confirm_product_import_path(import), params: { acknowledge_without_sku: "1" }
    end
    assert_response :unprocessable_entity
    with_csv("name,unit\nSin SKU,unit\n") { |upload| post product_imports_path, params: { file: upload } }
    import = companies(:one).product_imports.last
    post confirm_product_import_path(import)
    assert_response :unprocessable_entity
    assert_select ".flash.alert", text: /sin SKU/
    post confirm_product_import_path(import), params: { acknowledge_without_sku: "1" }
    assert_redirected_to products_path
  end

  test "previews and confirmation are tenant scoped and role protected" do
    import = companies(:two).product_imports.create!(headers: [ "name", "unit" ], rows: [ [ "Privado", "kg" ] ], mapping: { name: "0", unit: "1" })
    get product_import_path(import)
    assert_response :not_found
    patch product_import_path(import), params: { mapping: { name: "0" } }
    assert_response :not_found
    post confirm_product_import_path(import)
    assert_response :not_found
    sign_in_as users(:driver)
    post product_imports_path
    assert_response :forbidden
    post confirm_product_import_path(import)
    assert_response :forbidden
    sign_out
    get new_product_import_path
    assert_redirected_to new_session_path
  end

  private

  def with_csv(contents)
    Tempfile.create([ "products", ".csv" ]) do |file|
      file.write(contents)
      file.flush
      yield Rack::Test::UploadedFile.new(file.path, "text/csv")
    end
  end
end
