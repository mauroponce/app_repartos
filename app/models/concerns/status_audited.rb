module StatusAudited
  extend ActiveSupport::Concern
  included do
    after_create :record_initial_status
    after_update :record_status_transition, if: :saved_change_to_status?
  end

  private

  def record_initial_status
    return if validation_context == :historical_import
    record_status_event(nil)
  end

  def record_status_transition
    record_status_event(status_before_last_save)
  end

  def record_status_event(previous)
    actor = AuditContext.user
    actor ||= Current.user if Current.user&.company_id == company_id
    context = case self
    when Visit then { run_id: delivery_run_id }
    when DeliveryOrder then { visit_id: visit_id, run_id: visit&.delivery_run_id }
    else {}
    end
    DeliveryStatusEvent.create!(company: company, self.class.model_name.singular => self,
      user: actor, from_status: previous, to_status: status,
      source: AuditContext.source || (actor ? (actor.driver? ? "driver" : "manager") : "system"),
      operation_id: AuditContext.operation_id, occurred_at: Time.current,
      client_occurred_at: is_a?(Visit) && recorded_at_source == "device" ? recorded_at : nil, context: context)
  end
end
