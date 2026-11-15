module DriverApi
  module V1
    class WorkflowsController < ApplicationController
      before_action :require_driver
      before_action -> { response.headers["Cache-Control"] = "no-store" }
      around_action ->(_controller, action) { Time.use_zone(Current.company.time_zone, &action) }
      rescue_from WorkflowCommands::Forbidden, with: ->(error) { render json: { error: error.message }, status: :forbidden }
      rescue_from WorkflowCommands::Conflict, ActiveRecord::StaleObjectError, with: ->(error) { render json: { error: error.message }, status: :conflict }
      rescue_from ActiveRecord::RecordNotFound, with: -> { render json: { error: "El registro no está disponible para esta cuenta" }, status: :not_found }
      rescue_from ArgumentError, JSON::ParserError, ActiveRecord::RecordInvalid, with: ->(error) { render json: { error: error.message }, status: :unprocessable_entity }

      def inbox
        @inbox = DriverInbox.new(Current.user)
        pages = { notices: params[:page].to_i.clamp(1, 10_000), tasks: params[:tasks_page].to_i.clamp(1, 10_000), incidents: params[:incidents_page].to_i.clamp(1, 10_000) }
        render json: { html: render_to_string(partial: "driver_workflows/inbox", formats: [ :html ], locals: { inbox: @inbox, page: pages[:notices], tasks_page: pages[:tasks], incidents_page: pages[:incidents] }), pending: @inbox.pending_count, page_state: pages }
      end

      def incident
        @incident = Incident.visible_to_driver(Current.user).includes(:reporter, incident_photos: { file_attachment: :blob }).find(params[:id])
        render json: { html: render_to_string(partial: "driver_workflows/incident", formats: [ :html ], locals: { incident: @incident }) }
      end

      def create
        raise ArgumentError, "Operación demasiado grande" if params[:operation].to_s.bytesize > 100_000
        data = ActionController::Parameters.new(JSON.parse(params.require(:operation))).permit(:operation_id, :command, :id, :version, :visit_id, :delivery_run_id, :kind, :priority, :description, :occurred_at, :result, :message, photos: [ :id, :sha256 ]).to_h.deep_symbolize_keys
        id = data.delete(:operation_id)
        action = data.delete(:command)
        prepared = []
        if action == "incident_report"
          # A lost acknowledgement must not upload files a second time.
          unless Current.company.workflow_commands.exists?(operation_id: id)
            prepared = WorkflowPhotoUploads.prepare(params[:files], data[:photos])
          end
          result = IncidentRecorder.report(user: Current.user, operation_id: id, attributes: data, photos: prepared)
        else
          raise ArgumentError, "Esta acción no admite archivos" if params[:files].present?
          actions = WorkflowActions.new(Current.user)
          result = case action
          when "task_start", "task_complete"
            actions.update_task(id: data[:id], operation_id: id, attributes: { action: action == "task_start" ? "start" : "complete", version: data[:version], result: data[:result] })
          when "notice_read" then actions.read_notice(id: data[:id], operation_id: id)
          when "incident_information" then actions.incident_response(id: data[:id], operation_id: id, attributes: { message: data[:message] })
          else raise ArgumentError, "Acción no reconocida"
          end
        end
        render json: { operation_id: id, status: "synced", result: result }
      ensure
        prepared&.each { |row| row[:blob].purge_later if row[:blob].attachments.empty? }
      end

      private

      def require_driver
        head :forbidden unless Current.user.driver?
      end

      def request_authentication
        render json: { error: "authentication_required" }, status: :unauthorized
      end
    end
  end
end
