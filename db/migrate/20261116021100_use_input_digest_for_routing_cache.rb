class UseInputDigestForRoutingCache < ActiveRecord::Migration[8.1]
  def change
    rename_column :routing_cache_entries, :cache_key, :input_digest
  end
end
