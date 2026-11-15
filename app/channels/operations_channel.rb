class OperationsChannel < Turbo::StreamsChannel
  def subscribed
    current_user.reload
    expected = self.class.verified_stream_name(self.class.signed_stream_name([ current_user.company, :operations ]))
    if current_user.active? && current_user.manages_customers? && verified_stream_name_from_params == expected
      stream_from expected
    else
      reject
    end
  end
end
