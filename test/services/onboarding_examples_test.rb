require "test_helper"

class OnboardingExamplesTest < ActiveSupport::TestCase
  test "shared XLSX product catalog preserves text SKUs and normalizes Spanish units on repeated imports" do
    data = ProductImportReader.call(upload("productos_demo.xlsx"))
    assert_equal 16, data[:rows].size
    assert data[:rows].any? { |row| row.first == "000015" }
    2.times do
      import = companies(:one).product_imports.create!(**data, mapping: ProductImporter.default_mapping(data[:headers]))
      importer = ProductImporter.new(import)
      assert importer.preview.all? { |row| row.errors.empty? }, importer.preview.flat_map(&:errors).join(", ")
      assert_equal 16, importer.confirm!
      assert_equal 0, importer.confirm!
    end
    assert_equal 1, companies(:one).products.where(sku: "000015").count
    flour = companies(:one).products.find_by!(sku: "HAR-025")
    assert_equal "bag", flour.unit
    assert_equal "kg", flour.package_content_unit
    assert_equal 25.to_d, flour.package_content_quantity
    assert_equal "l", companies(:one).products.find_by!(sku: "ACE-001").package_content_unit
    assert_equal "unit", companies(:one).products.find_by!(sku: "GAL-012").package_content_unit
  end

  test "XLSX and CSV customers preserve phone original address locality and external code" do
    %w[clientes_demo.xlsx clientes_demo.csv clientes_demo_minimo.xlsx clientes_demo_minimo.csv].each do |filename|
      file = upload(filename)
      workbook = CustomerImports::Workbook.new(file.path, filename)
      metadata = workbook.metadata
      import = companies(:one).customer_imports.create!(state: "preparing", **metadata, mapping: CustomerImports::Preparation.mapping(metadata[:headers]))
      workbook.each_record(sheet_index: 0, header_row: metadata[:header_row]) do |values, number|
        import.import_rows.create!(company: companies(:one), number: number, original: values)
      end
      assert CustomerImports::Preparation.call(import)
      rows = import.import_rows.order(:number)
      assert_equal filename.include?("minimo") ? 6 : 30, rows.count
      assert_equal "Adrogué", rows.first.normalized["city"]
      assert_equal "Adrogué", rows.first.data["city"]
      assert_equal "1155551001", rows.first.data["phone"]
      assert_equal "Buenos Aires", rows.first.normalized["province"]
      assert_equal "Mitre 450", Geocoding::Address.query(rows.first.normalized)
      assert_nil rows.first.latitude
      assert_nil rows.first.longitude
      assert rows.all? { |row| row.issues.empty? }
      assert_equal "CLI-001", rows.first.data["external_code"] unless filename.include?("minimo")
    end
  end

  test "Spanish units in comma and semicolon CSV retain quantities and reject unknown or ambiguous units" do
    [ ",", ";" ].each do |separator|
      content = CSV.generate(col_sep: separator) do |csv|
        csv << [ "SKU", "Nombre", "Unidad", "Contenido", "Unidad de contenido" ]
        csv << [ "000901", "Café clásico", "BOLSA", "2,5", "kilogramo" ]
        csv << [ "000902", "Producto sin medida válida", "bulto", nil, nil ]
      end
      Tempfile.create([ "products", ".csv" ]) do |file|
        file.write(content)
        file.flush
        data = ProductImportReader.call(Rack::Test::UploadedFile.new(file.path, "text/csv"))
        import = companies(:one).product_imports.create!(**data, mapping: ProductImporter.default_mapping(data[:headers]))
        rows = ProductImporter.new(import).preview
        assert_empty rows.first.errors
        assert_equal "000901", rows.first.product.sku
        assert_equal "bag", rows.first.product.unit
        assert_equal BigDecimal("2.5"), rows.first.product.package_content_quantity
        assert rows.last.errors.any?
        assert_raises(ProductImporter::InvalidImport) { ProductImporter.new(import).confirm! }
      end
    end
  end

  private

  def upload(filename)
    Rack::Test::UploadedFile.new(Rails.root.join("docs/ejemplos/onboarding", filename), "application/octet-stream")
  end
end
