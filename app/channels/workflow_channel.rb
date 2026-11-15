class WorkflowChannel < Turbo::StreamsChannel
  def subscribed
    current_user.reload
    parts = if current_user.manages_customers?
      [ current_user.company, :workflow_admin ]
    else
      [ current_user.company, "user_#{current_user.id}", :workflow_driver ]
    end
    expected = self.class.verified_stream_name(self.class.signed_stream_name(parts))
    current_user.active? && verified_stream_name_from_params == expected ? stream_from(expected) : reject
  end
end
