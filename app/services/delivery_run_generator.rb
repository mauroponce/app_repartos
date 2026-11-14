# Compatibility entry point: recurrence generation now only creates orders.
# Route creation/assignment belongs to DeliveryRunPlanner and requires selection.
class DeliveryRunGenerator
  def self.call(company:, date:)
    DeliveryOrderGenerator.call(company: company, date: date)
  end
end
