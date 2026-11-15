require "test_helper"
require "tempfile"

class CustomerImporterTest < ActiveSupport::TestCase
  test "CSV aliases normalize contact data and preserve leading zero codes without premature writes" do
    import = csv_import("Código;Razón social;Teléfono;Correo;Domicilio;Localidad;Activo\n000123;Almacén; (11) 4444-5555 ; PEDIDOS@EXAMPLE.COM ;Mitre 123;Avellaneda;sí\n")
    assert_no_difference "Customer.count" do
      row = CustomerImporter.new(import).preview.first
      assert_empty row.errors
      assert_equal "000123", row.customer.external_code
      assert_equal "1144445555", row.customer.phone
      assert_equal "pedidos@example.com", row.customer.email
      assert_not row.customer.located?
    end
    assert_difference "Customer.count", 1 do
      result = confirm(import)
      assert_equal 1, result["created"]
      assert_equal 1, result["pending_location"]
    end
    assert_equal 1, confirm(import)["created"]
    assert_equal 1, companies(:one).customers.where(external_code: "000123").count
  end

  test "updates only matching tenant code and preserves blanks unless explicitly requested" do
    current = customers(:one)
    current.update!(external_code: "0001")
    foreign = customers(:other_company)
    foreign.update!(external_code: "0001")
    original_phone = current.phone
    import = csv_import("codigo,nombre,telefono,direccion,ciudad\n0001,Nombre nuevo,,,\n")
    row = CustomerImporter.new(import).preview.first
    assert_equal "Actualizar", row.action
    assert_includes row.changes, "Nombre"
    assert_equal original_phone, row.customer.phone
    assert_no_difference "Customer.count" do
      assert_equal 1, confirm(import)["updated"]
    end
    assert_equal "Nombre nuevo", current.reload.name
    assert_equal original_phone, current.phone
    assert_not_equal "Nombre nuevo", foreign.reload.name
    clear = csv_import("codigo,telefono\n0001,\n")
    clear.update!(overwrite_blanks: true)
    confirm(clear)
    assert_nil current.reload.phone
  end

  test "no code never merges names and requires duplicate acknowledgement" do
    current = customers(:one)
    import = csv_import("nombre,direccion,ciudad\n#{current.name},Otra 123,CABA\n")
    importer = CustomerImporter.new(import)
    assert importer.preview.first.warnings.any? { |message| message.include?("Coincidencias") }
    assert_raises(CustomerImporter::InvalidImport) { importer.confirm!(preview_digest: importer.digest) }
    assert_difference "Customer.count", 1 do
      confirm(import, acknowledge_duplicates: true)
    end
  end

  test "invalid coordinates duplicate codes and foreign references block all writes or can be explicitly excluded" do
    import = csv_import("codigo,nombre,direccion,ciudad,latitud,longitud,company_id\nA,Valido,Mitre 1,CABA,,,\nA,Invalido,Mitre 2,CABA,NaN,-58,#{companies(:two).id}\n")
    rows = CustomerImporter.new(import).preview
    assert_empty rows.first.errors
    assert rows.last.errors.any? { |message| message.include?("repetido") }
    assert rows.last.errors.any? { |message| message.include?("referencias internas") }
    assert rows.last.errors.any? { |message| message.include?("Coordenada inválida") }
    assert_no_difference "Customer.count" do
      assert_raises(CustomerImporter::InvalidImport) { confirm(import) }
    end
    import.update!(excluded_rows: [ 3 ])
    result = confirm(import)
    assert_equal 1, result["created"]
    assert_equal 1, result["skipped"]
  end

  test "valid coordinates can reconfirm an address change and absent points clear obsolete locations" do
    customer = customers(:one)
    customer.update!(external_code: "A")
    import = csv_import("codigo,direccion,latitud,longitud\nA,Nueva 1,#{customer.latitude},#{customer.longitude}\n")
    confirm(import)
    assert customer.reload.located?
    confirm(csv_import("codigo,direccion\nA,Otra 2\n"))
    assert_not customer.reload.located?
    [ [ "91", "10" ], [ "10", "-181" ], [ "10", "" ], [ "Infinity", "10" ] ].each do |lat, lon|
      bad = csv_import("nombre,direccion,ciudad,latitude,longitude\nBad,Calle 1,CABA,#{lat},#{lon}\n")
      assert CustomerImporter.new(bad).preview.first.errors.any?
    end
  end

  test "confirmation detects stale database values mapping and expiry" do
    customer = customers(:one)
    customer.update!(external_code: "A")
    import = csv_import("codigo,nombre\nA,Cambio\n")
    importer = CustomerImporter.new(import)
    digest = importer.digest
    customer.update!(phone: "123")
    assert_raises(CustomerImporter::InvalidImport) { importer.confirm!(preview_digest: digest) }
    import.update!(created_at: 25.hours.ago)
    assert_raises(CustomerImporter::InvalidImport) { confirm(import) }
  end

  test "database enforces tenant uniqueness and optional phone while rejecting blank codes" do
    customers(:one).update!(external_code: "A", phone: nil)
    assert customers(:other_company).update(external_code: "A")
    assert_raises(ActiveRecord::RecordNotUnique) do
      Customer.transaction(requires_new: true) { customers(:inactive).update_columns(external_code: "A") }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      Customer.transaction(requires_new: true) { Customer.connection.execute("UPDATE customers SET external_code = ' ' WHERE id = #{customers(:inactive).id}") }
    end
  end

  test "XLSX formatted numeric code and shared file protections are enforced" do
    upload = Rack::Test::UploadedFile.new(file_fixture("customers.xlsx"), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    data = CustomerImportReader.call(upload)
    import = companies(:one).customer_imports.create!(**data, mapping: CustomerImporter.default_mapping(data[:headers]))
    assert_equal "000123", CustomerImporter.new(import).preview.first.customer.external_code
    assert_equal 1, confirm(import)["created"]
    Tempfile.create([ "bomb", ".xlsx" ]) do |file|
      Zip::File.open(file.path, create: true) do |zip|
        zip.get_output_stream("xl/workbook.xml") { |stream| stream << "x" * 21.megabytes }
      end
      upload = Rack::Test::UploadedFile.new(file.path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      assert_raises(CustomerImportReader::InvalidFile) { CustomerImportReader.call(upload) }
    end
    with_csv("nombre,direccion,ciudad\nA,Calle,CABA\n", mime: "text/html") do |upload|
      assert_raises(CustomerImportReader::InvalidFile) { CustomerImportReader.call(upload) }
    end
  end

  private

  def confirm(import, **options)
    importer = CustomerImporter.new(import)
    importer.confirm!(preview_digest: importer.digest, **options)
  end

  def csv_import(content)
    with_csv(content) do |upload|
      data = CustomerImportReader.call(upload)
      companies(:one).customer_imports.create!(**data, mapping: CustomerImporter.default_mapping(data[:headers]))
    end
  end

  def with_csv(content, mime: "text/csv")
    Tempfile.create([ "customers", ".csv" ]) do |file|
      file.write(content)
      file.flush
      yield Rack::Test::UploadedFile.new(file.path, mime)
    end
  end
end
