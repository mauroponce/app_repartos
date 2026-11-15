class OperationsController < ManagementController
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def show
    @snapshot = OperationsSnapshot.new(company: Current.company)
  end

  def snapshot
    @snapshot = OperationsSnapshot.new(company: Current.company)
    render turbo_stream: [
      turbo_stream.replace("operations-stats", partial: "operations/stats", locals: { snapshot: @snapshot }),
      turbo_stream.replace("operations-board", partial: "operations/board", locals: { snapshot: @snapshot })
    ]
  end

  def change_assignment
    attributes = params.expect(dispatch: [ :target_run_id, :date, :revision, :reason ])
    OperationsDispatch.call(user: Current.user, order_id: params[:order_id], **attributes.to_h.symbolize_keys)
    redirect_to operations_path, notice: "Entrega actualizada. El repartidor recibirá el cambio al conectarse.", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    redirect_to operations_path, alert: error.message, status: :see_other
  end
end
