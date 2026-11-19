class OperationImportJob < ApplicationJob
  queue_as :customer_imports
  limits_concurrency to: 1, key: ->(company_id, *) { "operation-import-#{company_id}" }, duration: 30.minutes
  retry_on ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished, wait: :polynomially_longer, attempts: 5

  def perform(company_id, import_id, stage)
    batch = OperationImport.where(company_id: company_id).find_by(id: import_id)
    return unless batch
    processor = OperationImports::Processor.new(batch)
    case stage
    when "read"
      return unless batch.state == "reading"
      processor.read
      self.class.perform_later(company_id, import_id, "analyze")
    when "analyze"
      return unless batch.state == "analyzing"
      self.class.perform_later(company_id, import_id, "analyze") if processor.analyze_batch
    when "commit"
      return unless batch.state == "importing"
      self.class.perform_later(company_id, import_id, "commit") if processor.commit_batch
    end
  rescue OperationImports::Reader::InvalidFile => error
    batch&.update!(state: "failed", last_error: error.message)
  rescue ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished
    raise
  rescue StandardError => error
    batch&.update!(state: "failed", last_error: "El procesamiento se interrumpió: #{error.class.name}")
    Rails.logger.error("Operation import #{import_id}: #{error.class}: #{error.message}")
  end
end
