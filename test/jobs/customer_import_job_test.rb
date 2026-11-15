require "test_helper"
require_relative "../test_helpers/customer_import_test_helper"

class CustomerImportJobTest < ActiveJob::TestCase
  include CustomerImportTestHelper

  test "read map process and confirm are persistent asynchronous and idempotent" do
    import = smart_import
    assert_equal "mapping", import.state
    assert_equal 1, import.total_rows
    assert_equal [ "Nuevo", "Calle 450", "Adrogué" ], import.import_rows.first.original
    assert_no_difference "Customer.count" do
      prepare_smart_import(import)
    end
    assert_equal "review", import.state
    assert_equal 100, import.progress
    row = import.import_rows.first
    assert_equal "unlocated", row.precision
    assert_empty row.issues
    assert_raises(CustomerImports::Workflow::Invalid) { CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: false, acknowledge_pending: false) }
    CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: true, acknowledge_pending: true)
    assert_difference "Customer.count", 1 do
      perform_enqueued_jobs(only: CustomerImportJob)
    end
    assert_equal "completed", import.reload.state
    assert_equal "pending", row.reload.customer.location_verification
    assert_not row.customer.routing_location?
    CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: true, acknowledge_pending: true)
    assert_no_difference "Customer.count" do
      CustomerImportJob.perform_now(import.company_id, import.id, import.generation, "commit")
    end
  end

  test "supplied coordinates are preserved but blocked from routing until explicitly confirmed" do
    import = smart_import("nombre,direccion,ciudad,latitud,longitud\nA,Belgrano 450,Adrogué,-34.8,-58.39\n")
    prepare_smart_import(import)
    row = import.import_rows.first
    assert_equal "user", row.provider
    assert_equal "approximate", row.precision
    CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: true, acknowledge_pending: true)
    perform_enqueued_jobs(only: CustomerImportJob)
    customer = row.reload.customer
    assert customer.located?
    assert_equal "provided", customer.location_verification
    assert_not customer.routing_location?
    customer.location_confirmed = true
    assert customer.save(context: :geocoded)
    assert customer.routing_location?
    assert_equal "manual", customer.location_verification
  end

  test "duplicates and invalid rows are detected before any provider request and never overwrite existing clients" do
    existing = customers(:one)
    existing.update!(external_code: "A")
    import = smart_import("codigo,nombre,direccion,ciudad\nA,Cambio,Belgrano 450,Adrogué\nA,Cambio,Belgrano 450,Adrogué\nB,,Sin altura,\n")
    prepare_smart_import(import)
    rows = import.import_rows.order(:number).to_a
    assert rows.first.issues.any?
    assert rows.first.duplicates.any?
    assert rows.second.duplicates.any? { |message| message.include?("fila") }
    assert rows.third.issues.any?
    assert_not_equal "Cambio", existing.reload.name
    assert_raises(CustomerImports::Workflow::Invalid) { CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: true, acknowledge_pending: true) }
  end

  test "jobs and row foreign keys enforce tenant ownership and stale generations do no work" do
    import = smart_import
    CustomerImportJob.perform_now(companies(:two).id, import.id, import.generation, "read")
    assert_equal "mapping", import.reload.state
    CustomerImports::Workflow.cancel!(import)
    assert_equal "cancelled", import.state
    CustomerImportJob.perform_now(import.company_id, import.id, import.generation - 1, "read")
    assert_equal "cancelled", import.reload.state
    assert_raises(ActiveRecord::InvalidForeignKey) do
      CustomerImportRow.transaction(requires_new: true) do
        CustomerImportRow.insert_all!([ { company_id: companies(:two).id, customer_import_id: import.id, number: 100, original: [] } ])
      end
    end
  end

  test "cancel resume repeated processing and interrupted confirmation preserve committed rows" do
    import = smart_import("nombre,direccion,ciudad\nUno,Calle 1,Quilmes\nDos,Calle 2,Lanús\n")
    prepare_smart_import(import)
    CustomerImports::Workflow.cancel!(import)
    CustomerImports::Workflow.resume!(import)
    assert_equal "review", import.state
    CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: true, acknowledge_pending: true)
    first = import.import_rows.order(:number).first
    customer = companies(:one).customers.create!(name: first.data["name"], address: first.data["address"], city: first.data["city"], location_verification: "pending")
    first.update!(customer: customer)
    assert_difference "Customer.count", 1 do
      perform_enqueued_jobs(only: CustomerImportJob)
    end
    assert_equal 2, import.reload.summary["created"]
    assert_equal customer.id, first.reload.customer_id
  end

  test "100 500 and 2000 rows complete processing and final creation in bounded batches" do
    [ 100, 500, 2000 ].each do |size|
      csv = CSV.generate do |table|
        table << %w[nombre direccion ciudad]
        size.times { |index| table << [ "Cliente #{size}-#{index}", "Mitre 123", "Morón" ] }
      end
      import = smart_import(csv)
      assert_equal size, import.total_rows
      assert_equal size, import.import_rows.count
      assert_equal [], import.rows
      assert_equal "mapping", import.state
      prepare_smart_import(import)
      assert_equal "review", import.state
      assert_equal size, import.processed_rows
      CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: true, acknowledge_pending: true)
      assert_difference "Customer.count", size do
        drain_import_jobs
      end
      assert_equal "completed", import.reload.state
    end
  end

  test "empty malformed and formula workbooks fail without modifying customers" do
    import = companies(:one).customer_imports.create!(state: "reading", header_row: 0)
    import.source_file.attach(io: StringIO.new("nombre,direccion\n"), filename: "empty.csv", content_type: "text/csv")
    assert_no_difference "Customer.count" do
      CustomerImportJob.perform_now(import.company_id, import.id, import.generation, "read")
    end
    assert_equal "failed", import.reload.state
    assert import.last_error.present?
  end
  test "database deadlocks retry without marking the import permanently failed" do
    import = smart_import
    import.update!(state: "preparing")
    stub_method(CustomerImports::Preparation, :call, ->(*) { raise ActiveRecord::Deadlocked, "simulated" }) do
      assert_enqueued_with(job: CustomerImportJob) do
        CustomerImportJob.perform_now(import.company_id, import.id, import.generation, "prepare")
      end
    end
    assert_equal "preparing", import.reload.state
    assert_nil import.last_error
  end
end
