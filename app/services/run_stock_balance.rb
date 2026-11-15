class RunStockBalance
  def self.call(run)
    recorded = run.run_stock_movements.order(:id).to_a
    # Read actual execution for historical visits too; no loads are inferred
    # from plans, and no delivery is counted twice alongside its ledger entry.
    deliveries = run.visits.includes(:delivery_items).reject(&:pending?).flat_map(&:delivery_items)
    keys = (recorded.map { |row| [ row.product_id, row.product_id ? nil : row.description, row.unit ] } + deliveries.map { |row| [ row.product_id, row.product_id ? nil : row.description, row.unit ] }).uniq
    keys.map do |key|
      movements = recorded.select { |row| [ row.product_id, row.product_id ? nil : row.description, row.unit ] == key }
      actual = deliveries.select { |row| [ row.product_id, row.product_id ? nil : row.description, row.unit ] == key }
      delivered = actual.any? { |row| row.delivered_quantity.nil? } ? nil : actual.sum(0.to_d, &:delivered_quantity)
      totals = RunStockMovement::KINDS.keys.index_with { |kind| movements.select { |row| row.kind == kind }.sum(0.to_d, &:quantity) }
      totals["delivery"] = delivered
      known = movements.any? { |row| row.kind == "load" }
      { product_id: key[0], description: (movements.first&.description || deliveries.find { |item| [ item.product_id, item.product_id ? nil : item.description, item.unit ] == key }&.description || key[1]), unit: key[2], totals: totals, load_recorded: known,
        balance: known && delivered ? totals["load"] + totals["adjustment_in"] - delivered - totals["return"] - totals["waste"] - totals["adjustment_out"] : nil }
    end
  end
end
