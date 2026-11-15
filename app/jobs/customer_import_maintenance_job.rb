class CustomerImportMaintenanceJob < ApplicationJob
  queue_as :default

  def perform(company_id = nil)
    unless company_id
      Company.find_each { |company| self.class.perform_later(company.id) }
      return
    end
    scope = CustomerImport.where(company_id: company_id).where.not(state: "legacy")
    scope.where(state: %w[reading preparing processing importing]).where("heartbeat_at < ? OR heartbeat_at IS NULL", 10.minutes.ago).find_each do |import|
      next if import.expired? && import.state != "importing"
      action = { "reading" => "read", "preparing" => "prepare", "processing" => "process", "importing" => "commit" }.fetch(import.state)
      CustomerImports::Workflow.enqueue(import, action)
    end
    # Staging and files have a bounded retention; definitive customers survive.
    days = Geocoding::Config.integer("CUSTOMER_IMPORT_RETENTION_DAYS", 7, 2..90)
    scope.where.not(state: "importing").where("created_at < ?", days.days.ago).find_each(&:destroy!)
    GeocodingCacheEntry.where(company_id: company_id).where("expires_at < ?", Time.current).delete_all
  end
end
