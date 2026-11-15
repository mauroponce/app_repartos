class CustomerCommunicationsController < ManagementController
  before_action :set_customer

  def show
    @consents = @customer.communication_consents.includes(:user).order(id: :desc)
    @notifications = @customer.customer_notifications.includes(:notification_events).order(id: :desc).limit(50)
  end

  def create
    values = params.expect(consent: [ :channel, :purpose, :decision, :evidence ]).to_h
    Current.company.with_lock do
      raise ArgumentError, "La cuenta no puede registrar autorizaciones" unless Current.user.reload.active? && Current.user.manages_customers?
      previous = @customer.communication_consents.where(values.slice("channel", "purpose")).order(id: :desc).first
      unless previous && previous.decision == values["decision"] && previous.evidence == values["evidence"] && previous.recipient == CustomerNotification.recipient_for(@customer, values["channel"])
        @customer.communication_consents.create!(values.merge(company: Current.company, user: Current.user, occurred_at: Time.current))
      end
    end
    redirect_to customer_communications_path(@customer), notice: "Decisión registrada con su evidencia.", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    redirect_to customer_communications_path(@customer), alert: error.message, status: :see_other
  end

  private

  def set_customer
    @customer = Current.company.customers.find(params[:customer_id])
    response.headers["Cache-Control"] = "no-store"
  end
end
