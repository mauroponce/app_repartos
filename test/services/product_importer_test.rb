require "test_helper"
require "tempfile"

class ProductImporterTest < ActiveSupport::TestCase
  test "CSV preview validates without writing and confirm imports atomically" do
    import = csv_import("sku,name,unit,package_content_quantity,package_content_unit,active\nNEW-01,Harina,bag,25,kg,true\nNEW-02,Aceite,l,0.75,l,false\n")
    assert_no_difference "Product.count" do
      preview = ProductImporter.new(import).preview
      assert preview.all? { |row| row.errors.empty? }
      assert_equal [ 2, 3 ], preview.map(&:number)
    end
    assert_difference "companies(:one).products.count", 2 do
      assert_equal 2, ProductImporter.new(import).confirm!
    end
    assert import.reload.confirmed_at
    assert_equal "bag", companies(:one).products.find_by!(sku: "NEW-01").unit
    assert_not companies(:one).products.find_by!(sku: "NEW-02").active?
    assert_no_difference "Product.count" do
      assert_equal 0, ProductImporter.new(import).confirm!
    end
  end

  test "XLSX uses roo and reads numeric decimal quantities" do
    upload = Rack::Test::UploadedFile.new(file_fixture("products.xlsx"), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    data = ProductImportReader.call(upload)
    import = companies(:one).product_imports.create!(**data, mapping: ProductImporter.default_mapping(data[:headers]))
    assert_equal 2, ProductImporter.new(import).confirm!
    assert_equal 25, companies(:one).products.find_by!(sku: "XLS-01").package_content_quantity
    assert_equal BigDecimal("0.75"), companies(:one).products.find_by!(sku: "XLS-02").package_content_quantity
  end

  test "SKU reimport updates only the import company and never matches by name" do
    other = companies(:two).products.create!(name: "Otro pan", unit: "pack", sku: "PAN-01")
    import = csv_import("sku,name,unit\nPAN-01,Pan actualizado,pack\n")
    assert_no_difference "Product.count" do
      ProductImporter.new(import).confirm!
    end
    assert_equal "Pan actualizado", products(:bread).reload.name
    assert_equal "Otro pan", other.reload.name
    no_sku = csv_import("name,unit\nPan actualizado,pack\n")
    assert_raises(ProductImporter::InvalidImport) { ProductImporter.new(no_sku).confirm! }
    assert_difference "Product.count", 1 do
      ProductImporter.new(no_sku).confirm!(acknowledge_without_sku: true)
    end
  end

  test "row errors prevent the entire import including otherwise valid updates" do
    import = csv_import("sku,name,unit\nPAN-01,Cambio que no se guarda,pack\nNEW-02,Producto inválido,pallet\n")
    rows = ProductImporter.new(import).preview
    assert_empty rows[0].errors
    assert rows[1].errors.any?
    assert_equal 3, rows[1].number
    assert_no_difference "Product.count" do
      assert_raises(ProductImporter::InvalidImport) { ProductImporter.new(import).confirm! }
    end
    assert_equal "Pan lactal", products(:bread).reload.name
    assert_nil import.reload.confirmed_at
  end

  test "duplicate SKUs and invalid boolean or numeric values are reported" do
    import = csv_import("sku,name,unit,package_content_quantity,package_content_unit,active\nA,Uno,bag,25,kg,true\nA,Dos,bag,wat,kg,maybe\n")
    rows = ProductImporter.new(import).preview
    assert rows[1].errors.any? { |error| error.include?("SKU repetido") }
    assert rows[1].errors.any? { |error| error.include?("decimal inválido") }
    assert_raises(ProductImporter::InvalidImport) { ProductImporter.new(import).confirm! }
    boolean = csv_import("name,unit,active\nTest,kg,maybe\n")
    assert ProductImporter.new(boolean).preview.first.errors.any? { |error| error.include?("Activo debe") }
  end

  test "decimal commas and common thousands separators parse strictly" do
    import = csv_import("nombre;unidad;contenido;unidad de contenido;activo\nAceite;l;0,750;l;sí\nHarina;bag;1.234,500;kg;no\nNueces;kg;1,234.500;g;1\n")
    assert_equal 3, ProductImporter.new(import).confirm!(acknowledge_without_sku: true)
    assert_equal BigDecimal("0.75"), companies(:one).products.find_by!(name: "Aceite").package_content_quantity
    assert_equal BigDecimal("1234.5"), companies(:one).products.find_by!(name: "Harina").package_content_quantity
    assert_equal BigDecimal("1234.5"), companies(:one).products.find_by!(name: "Nueces").package_content_quantity
    invalid = csv_import("name;unit;package_content_quantity;package_content_unit\nNo;kg;1,1234;kg\n")
    assert ProductImporter.new(invalid).preview.first.errors.any?
  end

  test "unknown columns can be mapped and tenant columns are ignored" do
    import = csv_import("Descripción;Medida;company_id\nPrueba;box;#{companies(:two).id}\n")
    assert ProductImporter.new(import).preview.first.errors.any?
    import.update!(mapping: { "name" => "0", "unit" => "1", "company_id" => "2" })
    ProductImporter.new(import).confirm!(acknowledge_without_sku: true)
    assert_equal companies(:one), Product.find_by!(name: "Prueba").company
  end

  test "oversized unsupported malformed empty and headerless files fail explicitly" do
    fake = Struct.new(:size).new(6.megabytes)
    assert_raises(ProductImportReader::InvalidFile) { ProductImportReader.call(fake) }
    assert_raises(ProductImportReader::InvalidFile) { ProductImportReader.call(nil) }
    [ [ "name,unit\n", ".csv" ], [ "x,x\na,b\n", ".csv" ], [ "name,unit\n\"broken", ".csv" ], [ "invalid", ".xlsx" ], [ "name,unit\nA,kg", ".xls" ] ].each do |contents, extension|
      with_upload(contents, extension) do |upload|
        assert_raises(ProductImportReader::InvalidFile) { ProductImportReader.call(upload) }
      end
    end
  end

  test "expired previews cannot import and row limits are enforced" do
    import = csv_import("name,unit\nTest,unit\n")
    import.update!(created_at: 25.hours.ago)
    assert_raises(ProductImporter::InvalidImport) { ProductImporter.new(import).confirm!(acknowledge_without_sku: true) }
    with_upload("name,unit\n" + "Test,unit\n" * 1001, ".csv") do |upload|
      assert_raises(ProductImportReader::InvalidFile) { ProductImportReader.call(upload) }
    end
  end

  test "blank lines preserve spreadsheet row numbers in validation errors" do
    import = csv_import("name,unit\nValid,kg\n\nInvalid,pallet\n")
    rows = ProductImporter.new(import).preview
    assert_equal [ 2, 4 ], rows.map(&:number)
    assert rows.last.errors.any?
  end

  private

  def csv_import(contents)
    with_upload(contents, ".csv") do |upload|
      data = ProductImportReader.call(upload)
      companies(:one).product_imports.create!(**data, mapping: ProductImporter.default_mapping(data[:headers]))
    end
  end

  def with_upload(contents, extension)
    Tempfile.create([ "products", extension ]) do |file|
      file.write(contents)
      file.flush
      yield Rack::Test::UploadedFile.new(file.path, "application/octet-stream")
    end
  end
end
