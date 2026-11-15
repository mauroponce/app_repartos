class RoutingCacheEntry < ApplicationRecord
  include TenantIntegrity
  validates :kind, inclusion: { in: %w[matrix solution geometry] }
  validates :input_digest, format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: { scope: %i[company_id kind] }

  # One database-backed cache, partitioned by tenant. A per-key advisory lock
  # coalesces simultaneous misses without holding the company's planning lock.
  def self.fetch(company:, kind:, key:)
    scope = where(company: company, kind: kind, input_digest: key)
    entry = scope.first
    unless entry
      transaction do
        lock_key = Digest::SHA256.hexdigest([ company.id, kind, key ].join(":"))[0, 16].to_i(16)
        lock_key -= 2**64 if lock_key >= 2**63
        bind = ActiveRecord::Relation::QueryAttribute.new("lock_key", lock_key, ActiveRecord::Type::Integer.new(limit: 8))
        connection.exec_query("SELECT pg_advisory_xact_lock($1)", "Routing cache lock", [ bind ])
        entry = scope.first || create!(company: company, kind: kind, input_digest: key, data: yield, last_used_at: Time.current)
      end
    end
    entry.update_columns(last_used_at: Time.current) if entry.last_used_at < 1.day.ago
    entry.data.deep_symbolize_keys
  end
end
