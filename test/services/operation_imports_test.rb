require "test_helper"
require "tempfile"

class OperationImportsTest < ActiveSupport::TestCase
  def setup
    @company = companies(:one)
  end

  test "template streams and groups weekly products without inventing visits" do
    batch = batch_from_file(Rails.root.join("docs/ejemplos/operacion/plantilla_importacion_operacion.xlsx"))
    processor = OperationImports::Processor.new(batch)
    processor.read
    processor.analyze_batch while batch.reload.state == "analyzing"
    assert_equal "review", batch.reload.state
    assert batch.groups.where(state: "ready").exists?
    assert batch.groups.where("data->>'tipo_pedido' = ?", "visita_semanal").exists?
  end

  test "same source is not duplicated and weekly visits have no merchandise" do
    csv = csv_rows([
      [ "Juan Pérez", "Cliente A", "visita_semanal", "", "lunes", "", "", "Burzaco", "San Martin 123", "", "", "", "", "1" ],
      [ "Juan Pérez", "Cliente A", "pedido_semanal", "", "martes", "", "", "Burzaco", "San Martin 123", "Coca Cola 2 L", "20", "", "", "2" ],
      [ "Juan Pérez", "Cliente A", "pedido_semanal", "", "martes", "", "", "Burzaco", "San Martin 123", "Pan x 6", "15", "", "", "2" ]
    ])
    batch = process_csv(csv)
    assert_equal 2, batch.groups.where(state: "ready").count
    batch.update!(state: "importing")
    processor = OperationImports::Processor.new(batch)
    processor.commit_batch while batch.reload.state == "importing"
    schedules = @company.delivery_schedules.where.not(import_key: nil).order(:weekday)
    assert_equal 2, schedules.count
    assert_equal 0, schedules.first.delivery_schedule_items.count
    assert_equal 2, schedules.last.delivery_schedule_items.count
    monday_orders = DeliveryOrderGenerator.call(company: @company, date: "2026-11-23")
    assert_empty monday_orders.select { |order| order.delivery_schedule_id.in?(schedules.pluck(:id)) }
    tuesday_orders = DeliveryOrderGenerator.call(company: @company, date: "2026-11-24")
    imported_orders = tuesday_orders.select { |order| order.delivery_schedule_id.in?(schedules.pluck(:id)) }
    assert_equal 1, imported_orders.size
    assert_equal [ 15, 20 ], imported_orders.first.delivery_order_items.pluck(:quantity).map(&:to_i).sort
    assert_equal 1, @company.driver_profiles.where(name_key: "juan perez").count
    assert_equal 1, @company.customers.where(name: "Cliente A").count
    replacement = @company.driver_profiles.create!(name: "Otro repartidor", name_key: "otro repartidor")
    schedules.last.update!(driver_profile: replacement)
    other = process_csv(csv)
    assert_equal 2, other.groups.where(state: "duplicate").count
    assert_equal replacement, schedules.last.reload.driver_profile
  end

  test "bad group does not block valid group" do
    csv = csv_rows([
      [ "Juan", "Cliente A", "pedido_puntual", "2026-11-25", "lunes", "", "", "Burzaco", "Uno 123", "Pan", "2", "", "", "" ],
      [ "Ana", "Cliente B", "visita_semanal", "", "jueves", "", "", "Burzaco", "Dos 123", "", "", "", "", "" ]
    ])
    batch = process_csv(csv)
    assert_equal 1, batch.groups.where(state: "review").count
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal 1, batch.groups.where(state: "imported").count
  end

  test "a repeated product without reference needs review and never creates an order" do
    row = [ "Ana", "Cliente", "pedido_puntual", "2026-11-25", "", "09:00", "10:00", "Burzaco", "Uno 123", "Pan", "2", "", "", "" ]
    batch = process_csv(csv_rows([ row, row ]))
    assert_equal 1, batch.groups.where(state: "review").count
    assert_match(/Posibles pedidos independientes/, batch.groups.first.issues.join)
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal 0, @company.delivery_orders.where.not(import_key: nil).count
  end

  test "same client name at different addresses remains separate" do
    rows = [ "Uno 123", "Dos 234" ].map do |street|
      [ "Ana", "Kiosco", "visita_semanal", "", "lunes", "", "", "Burzaco", street, "", "", "", "", "" ]
    end
    batch = process_csv(csv_rows(rows))
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal 2, @company.customers.where(name: "Kiosco").count
  end

  test "existing customer code with different identity is reviewed" do
    @company.customers.create!(name: "Original", address: "Uno 123", city: "Burzaco", external_code: "A-1")
    row = [ "Ana", "Otro", "visita_semanal", "", "lunes", "", "", "Burzaco", "Dos 234", "", "", "A-1", "", "" ]
    batch = process_csv(csv_rows([ row ]))
    assert_equal "review", batch.groups.first.state
    assert_match(/código/i, batch.groups.first.issues.join)
  end

  test "a matched customer without a code receives the imported code" do
    customer = @company.customers.create!(name: "Kiosco", address: "Uno 123", city: "Burzaco")
    row = [ "Ana", "Kiosco", "visita_semanal", "", "lunes", "", "", "Burzaco", "Uno 123", "", "", "K-1", "", "" ]
    batch = process_csv(csv_rows([ row ]))
    assert_equal customer, batch.groups.first.customer
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal "K-1", customer.reload.external_code
    assert_equal 1, @company.customers.where(name: "Kiosco").count
  end

  test "same code with conflicting addresses is reviewed before confirmation" do
    rows = [ "Uno 123", "Dos 234" ].map do |street|
      [ "Ana", "Kiosco", "visita_semanal", "", "lunes", "", "", "Burzaco", street, "", "", "A-1", "", "" ]
    end
    batch = process_csv(csv_rows(rows))
    assert_equal 1, batch.groups.where(state: "review").count
    assert batch.groups.all? { |group| group.issues.join.include?("mismo código") }
  end

  test "same names in another company are not reused" do
    companies(:two).driver_profiles.create!(name: "Ana", name_key: "ana")
    companies(:two).customers.create!(name: "Kiosco", address: "Uno 123", city: "Burzaco")
    row = [ "Ana", "Kiosco", "visita_semanal", "", "lunes", "", "", "Burzaco", "Uno 123", "", "", "", "", "" ]
    batch = process_csv(csv_rows([ row ]))
    assert_nil batch.groups.first.driver_profile_id
    assert_nil batch.groups.first.customer_id
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal 1, @company.driver_profiles.where(name_key: "ana").count
  end

  test "accent and case variants reuse the same customer and product" do
    customer = @company.customers.create!(name: "Kiosco José", address: "Avenida San Martín 123", city: "Burzaco")
    product = @company.products.create!(name: "Café Molido", unit: "unit")
    row = [ "Ana", "KIOSCO JOSE", "pedido_puntual", "2026-11-25", "", "", "", "Burzaco", "Avenida San Martin 123", "Cafe Molido", "2", "", "", "" ]
    batch = process_csv(csv_rows([ row ]))
    assert_equal customer, batch.groups.first.customer
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal product, @company.delivery_orders.find_by!(import_key: batch.groups.first.group_key).delivery_order_items.first.product
  end

  test "a large punctual order saves its lines in batches with catalog snapshots" do
    catalog_product = @company.products.create!(name: "Producto 0", unit: "unit", unit_price: 125.50, unit_cost: 80)
    rows = 205.times.map do |index|
      [ "Ana", "Cliente", "pedido_puntual", "2026-11-25", "", "09:00", "10:00", "Burzaco", "Uno 123",
        "Producto #{index}", "2", "", "", "" ]
    end
    batch = process_csv(csv_rows(rows))
    assert_equal "ready", batch.groups.first.state
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch

    order = @company.delivery_orders.find_by!(import_key: batch.groups.first.group_key)
    assert_equal 205, order.delivery_order_items.count
    assert_equal (0...205).to_a, order.delivery_order_items.order(:position).pluck(:position)
    first_item = order.delivery_order_items.order(:position).first
    assert_equal catalog_product, first_item.product
    assert_equal catalog_product.unit_price, first_item.unit_price
    assert_equal catalog_product.unit_cost, first_item.unit_cost
    assert_equal @company.currency, first_item.currency
  end

  test "inactive matching product moves the group to review" do
    @company.products.create!(name: "Pan", unit: "unit", active: false)
    row = [ "Ana", "Cliente", "pedido_puntual", "2026-11-25", "", "", "", "Burzaco", "Uno 123", "Pan", "2", "", "", "" ]
    batch = process_csv(csv_rows([ row ]))
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal "review", batch.groups.first.reload.state
    assert_equal 0, @company.delivery_orders.where.not(import_key: nil).count
  end

  test "existing product with a different unit needs review" do
    @company.products.create!(name: "Harina", unit: "kg")
    row = [ "Ana", "Cliente", "pedido_puntual", "2026-11-25", "", "", "", "Burzaco", "Uno 123", "Harina", "2", "", "", "" ]
    batch = process_csv(csv_rows([ row ]))
    batch.update!(state: "importing")
    OperationImports::Processor.new(batch).commit_batch
    assert_equal "review", batch.groups.first.reload.state
    assert_equal 0, @company.delivery_orders.where.not(import_key: nil).count
  end

  test "references separate otherwise identical punctual orders" do
    rows = %w[A B].map do |reference|
      [ "Ana", "Cliente", "pedido_puntual", "2026-11-25", "", "09:00", "10:00", "Burzaco", "Uno 123", "Pan", "2", "", reference, "" ]
    end
    batch = process_csv(csv_rows(rows))
    assert_equal 2, batch.groups.where(state: "ready").count
    batch.update!(state: "importing")
    processor = OperationImports::Processor.new(batch)
    processor.commit_batch
    processor.commit_batch
    assert_equal 2, @company.delivery_orders.where.not(import_key: nil).count
  end

  test "a group made stale by another import creates no extra identities" do
    row = [ "Ana", "Kiosco", "visita_semanal", "", "lunes", "", "", "Burzaco", "Uno 123", "", "", "", "", "" ]
    csv = csv_rows([ row ])
    first = process_csv(csv)
    second = process_csv(csv)
    [ first, second ].each { |batch| batch.update!(state: "importing") }
    OperationImports::Processor.new(first).commit_batch
    OperationImports::Processor.new(second).commit_batch
    assert_equal "duplicate", second.groups.first.reload.state
    assert_equal 1, @company.customers.where(name: "Kiosco").count
    assert_equal 1, @company.driver_profiles.where(name_key: "ana").count
    assert_equal 1, @company.delivery_schedules.where.not(import_key: nil).count
  end

  test "incompatible dates weekdays and hours remain in review" do
    rows = [
      [ "Ana", "A", "pedido_puntual", "2026-11-25", "lunes", "", "", "Burzaco", "Uno 123", "Pan", "2", "", "", "" ],
      [ "Ana", "B", "pedido_semanal", "2026-11-25", "martes", "", "", "Burzaco", "Dos 123", "Pan", "2", "", "", "" ],
      [ "Ana", "C", "pedido_puntual", "2026-11-25", "", "10:00", "09:00", "Burzaco", "Tres 123", "Pan", "2", "", "", "" ]
    ]
    batch = process_csv(csv_rows(rows))
    assert_equal 3, batch.groups.where(state: "review").count
    assert batch.groups.all? { |group| group.issues.any? }
  end

  test "reader streams more than thirty thousand rows" do
    Tempfile.create([ "operation", ".csv" ]) do |file|
      file.write(OperationImports::Reader::HEADERS.join(",") + "\n")
      30_001.times { |i| file.write("Ana,Cliente #{i},visita_semanal,,lunes,,,Burzaco,Calle #{i},,,,,\n") }
      file.flush
      count = 0
      OperationImports::Reader.new(file.path, "operation.csv").each_row { |_, _| count += 1 }
      assert_equal 30_001, count
    end
  end

  test "reader rejects unexpected columns before persisting their values" do
    Tempfile.create([ "operation", ".csv" ]) do |file|
      file.write(OperationImports::Reader::HEADERS.join(",") + "\n" + ([ "Ana" ] * 15).join(",") + "\n")
      file.flush
      assert_raises(OperationImports::Reader::InvalidFile) do
        OperationImports::Reader.new(file.path, "operation.csv").each_row { |_, _| flunk "No debe emitir la fila" }
      end
    end
  end

  private

  def csv_rows(rows)
    CSV.generate do |csv|
      csv << OperationImports::Reader::HEADERS
      rows.each { |row| csv << row }
    end
  end

  def batch_from_file(path)
    batch = @company.operation_imports.create!(sha256: SecureRandom.hex(32))
    batch.source_file.attach(io: File.open(path), filename: File.basename(path), content_type: path.to_s.end_with?(".csv") ? "text/csv" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    batch
  end

  def process_csv(content)
    Tempfile.create([ "operation", ".csv" ]) do |file|
      file.write(content)
      file.flush
      batch = batch_from_file(file.path)
      processor = OperationImports::Processor.new(batch)
      processor.read
      processor.analyze_batch while batch.reload.state == "analyzing"
      batch
    end
  end
end
