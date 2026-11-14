namespace :delivery_orders do
  desc "Convert legacy scheduled visits in tenant-scoped transactional batches (optional COMPANY_ID)"
  task backfill: :environment do
    companies = ENV["COMPANY_ID"].present? ? Company.where(id: ENV.fetch("COMPANY_ID")) : Company.all
    companies.find_each do |company|
      count = 0
      company.visits.where.not(delivery_schedule_id: nil).in_batches(of: 100) do |batch|
        count += DeliveryOrderBackfill.call(company: company, visit_ids: batch.pluck(:id))
      end
      puts "Company #{company.id}: #{count} deliveries converted"
    end
  end
end
