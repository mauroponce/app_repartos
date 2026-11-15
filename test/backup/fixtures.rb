require "base64"
require "digest"
raise "Backup fixtures only run in test" unless Rails.env.test?
original = ApplicationRecord.connection_db_config.configuration_hash
primary = original.merge(database: "app_repartos_backup_test")
queue = original.merge(database: "app_repartos_backup_queue_test")
[ primary, queue ].each { |config| ActiveRecord::Tasks::DatabaseTasks.create(config) }
ActiveRecord::Schema.verbose = false
ActiveRecord::Base.establish_connection(queue)
load Rails.root.join("db/queue_schema.rb")
ActiveRecord::Base.establish_connection(primary)
load Rails.root.join("db/schema.rb")
ApplicationRecord.descendants.each(&:reset_column_information)
ActiveJob::Base.queue_adapter = :test
company = Company.create!(name: "Backup technical fixture", slug: "backup-fixture")
driver = User.create!(company: company, name: "Recovery fixture", email_address: "recovery@example.test",
  password: "technical-fixture-only", role: :driver, status: :active, location_sharing_enabled: true,
  location_consent_id: SecureRandom.uuid, location_consent_version: 1, location_activated_at: Time.current)
Session.create!(user: driver)
DriverLocation.create!(company: company, user: driver, latitude: -34.6, longitude: -58.4,
  accuracy: 10, captured_at: Time.current, sharing: true)
rows = [ [ "abcdbackupfixturelocal001", "persistent", "Local fixture attachment\n" ], [ "efghbackupfixtureremote01", "r2", "Remote fixture attachment\n" ] ].map do |key, service, data|
  # Simulate the catalog without constructing an S3 client or contacting R2.
  ActiveStorage::Blob.insert_all!([ { key: key, filename: "fixture.txt", content_type: "text/plain", byte_size: data.bytesize,
    checksum: Base64.strict_encode64(Digest::MD5.digest(data)), service_name: service, created_at: Time.current } ])
  { key: key, service: service, data: data }
end
puts({ primary: primary[:database], queue: queue[:database], files: rows }.to_json)
