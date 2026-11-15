module WorkflowUpdates
  extend ActiveSupport::Concern
  included { after_commit :broadcast_workflow_change }

  private

  def broadcast_workflow_change
    Turbo::StreamsChannel.broadcast_action_to(company, :workflow_admin, action: "workflow_refresh")
    recipients = case self
    when InternalNotice then [ user_id ]
    when WorkflowTask then [ assignee_id, delivery_run&.driver_id ]
    when Incident then [ reporter_id ]
    else []
    end
    recipients.compact.uniq.each do |id|
      Turbo::StreamsChannel.broadcast_action_to(company, "user_#{id}", :workflow_driver, action: "workflow_refresh")
    end
  rescue StandardError => error
    Rails.logger.warn("Workflow invalidation unavailable: #{error.class.name}")
  end
end
