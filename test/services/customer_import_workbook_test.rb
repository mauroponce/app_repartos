require "test_helper"
require_relative "../test_helpers/customer_import_test_helper"

class CustomerImportWorkbookTest < ActiveSupport::TestCase
  include CustomerImportTestHelper

  test "all demonstration workbooks stream and support selecting a second sheet" do
    %w[simple incompleta ambigua grande].each do |kind|
      path = Rails.root.join("docs/ejemplos/clientes/clientes_importacion_#{kind}.xlsx")
      book = CustomerImports::Workbook.new(path, path.basename)
      metadata = book.metadata
      rows = []
      book.each_record(sheet_index: 0, header_row: metadata[:header_row]) { |values, number| rows << values }
      assert rows.any?
      assert_equal 2000, rows.size if kind == "grande"
      assert_equal "Código", metadata[:headers].first
      next unless kind == "simple"
      assert_equal 2, metadata[:sheet_names].size
      second = book.metadata(sheet_index: 1)
      assert_equal 1, second[:header_row]
      book.each_record(sheet_index: 1, header_row: 1) { |values, number| assert_equal "DEMO-HOJA-2", values.first }
    end
  end

  test "Excel zero masks remain intact and formulas are rejected" do
    path = file_fixture("customers.xlsx")
    book = CustomerImports::Workbook.new(path, "customers.xlsx")
    rows = []
    book.each_record(sheet_index: 0, header_row: 1) { |values, _| rows << values }
    assert_equal "000123", rows.first.first
    Tempfile.create([ "formula", ".xlsx" ]) do |file|
      FileUtils.cp(path, file.path)
      Zip::File.open(file.path) do |archive|
        entry = archive.glob("xl/worksheets/sheet*.xml").first
        xml = entry.get_input_stream.read.sub("<v>123</v>", "<f>1+122</f><v>123</v>")
        archive.get_output_stream(entry.name) { |stream| stream.write(xml) }
      end
      modified = CustomerImports::Workbook.new(file.path, "formula.xlsx")
      assert_raises(CustomerImports::Workbook::InvalidFile) { modified.each_record(sheet_index: 0, header_row: 1) { } }
    end
  end

  test "row limits malformed CSV and unsupported file content are rejected" do
    with_env("CUSTOMER_IMPORT_MAX_ROWS" => "1") do
      Tempfile.create([ "limits", ".csv" ]) do |file|
        file.write("nombre,direccion\nUno,Calle 1\nDos,Calle 2\n")
        file.flush
        book = CustomerImports::Workbook.new(file.path, "limits.csv")
        assert_raises(CustomerImports::Workbook::InvalidFile) { book.each_record(sheet_index: 0, header_row: 1) { } }
      end
    end
    Tempfile.create([ "binary", ".csv" ]) do |file|
      file.write("nombre\n\0\n")
      file.flush
      assert_raises(CustomerImports::Workbook::InvalidFile) { CustomerImports::Workbook.new(file.path, "binary.csv").metadata }
    end
    assert_raises(CustomerImports::Workbook::InvalidFile) { CustomerImports::Workbook.validate_upload!(nil) }
  end
end
