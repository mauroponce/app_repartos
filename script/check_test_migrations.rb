# Rails 8.1 db:migrate can initialize an empty DB from schema.rb. Exercise the
# actual migration history in a separate disposable test DB, without that path.
raise "Migration verification requires test" unless Rails.env.test?
original = ActiveRecord::Base.connection_db_config.configuration_hash
database = "app_repartos_migrations_test_#{SecureRandom.hex(6)}"
created = false
begin
  ActiveRecord::Base.connection.create_database(database)
  created = true
  ActiveRecord::Base.establish_connection(original.merge(database: database))
  context = ActiveRecord::MigrationContext.new([ Rails.root.join("db/migrate").to_s ])
  context.migrate
  raise "Migration history is incomplete" if context.needs_migration?
  raise "Platform migration is missing" unless ActiveRecord::Base.connection.column_exists?(:companies, :primary_administrator_id)
  raise "Fresh migration unexpectedly created privileged accounts" unless PlatformAdmin.count.zero?
  puts({ fresh_migrations: "OK", count: context.get_all_versions.size }.to_json)
ensure
  ActiveRecord::Base.establish_connection(original)
  ActiveRecord::Base.connection.drop_database(database) if created
end
