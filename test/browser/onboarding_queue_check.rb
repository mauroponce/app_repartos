# Exercise actual Solid Queue persistence, concurrency and chained jobs against
# the disposable test databases. External HTTP responses come from the managed
# Playwright provider stub; no public geocoding endpoint is contacted.
raise "Queue check requires test" unless Rails.env.test?
ENV["GEOREF_API_URL"] = "http://127.0.0.1:#{ENV.fetch('PWA_GEOCODING_PORT', '3198')}/georef"
ENV["PHOTON_URL"] = "http://127.0.0.1:#{ENV.fetch('PWA_GEOCODING_PORT', '3198')}/photon"
ENV["GEOREF_INTERVAL_MS"] = ENV["PHOTON_INTERVAL_MS"] = "0"
ENV["GEMINI_ENABLED"] = "false"
CustomerImportJob.queue_adapter = :solid_queue
company = Company.create!(slug: "onboarding-queue-#{SecureRandom.hex(6)}", name: "Prueba Solid Queue")
worker = nil
begin
  import = company.customer_imports.create!(state: "reading", header_row: 0,
    source_file: { io: File.open(Rails.root.join("docs/ejemplos/onboarding/clientes_demo_minimo.xlsx")), filename: "clientes_demo_minimo.xlsx" })
  CustomerImports::Workflow.enqueue(import, "read")
  queued = SolidQueue::Job.where(class_name: "CustomerImportJob").where("arguments::jsonb->'arguments'->>0 = ?", company.id.to_s)
  raise "The read job was not persisted in Solid Queue" unless queued.count == 1
  worker = SolidQueue::Worker.new(queues: [ "customer_imports" ], threads: 1, polling_interval: 0.1)
  worker.start
  wait_for = lambda do |state|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
    until import.reload.state == state
      raise "Import failed: #{import.last_error}" if import.state == "failed"
      raise "Queue timed out at #{import.state}, expected #{state}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end
  wait_for.call("mapping")
  CustomerImports::Workflow.start!(import)
  wait_for.call("review")
  raise "Expected six reliable HTTP fixture results" unless import.import_rows.where(review_state: "automatic").count == 6
  CustomerImports::Workflow.confirm!(import, acknowledge_duplicates: false, acknowledge_pending: false)
  wait_for.call("completed")
  raise "Queue did not create all customers" unless company.customers.count == 6
  worker.stop
  worker = nil
  raise "Chained queue stages were not recorded as finished" unless queued.where.not(finished_at: nil).count == 4
  puts({ solid_queue: "OK", finished_jobs: 4, customers: company.customers.count, state: import.state }.to_json)
ensure
  worker&.stop
  SolidQueue::Job.where(class_name: "CustomerImportJob").where("arguments::jsonb->'arguments'->>0 = ?", company.id.to_s).destroy_all
  company.customer_imports.each { |record| record.source_file.purge; record.destroy! }
  [ GeocodingCacheEntry, Customer ].each { |model| model.where(company: company).delete_all }
  company.destroy!
end
