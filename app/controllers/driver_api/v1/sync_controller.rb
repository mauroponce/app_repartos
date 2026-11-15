module DriverApi
  module V1
    class SyncController < ApplicationController
      include DriverDashboard
      before_action :require_api_driver
      prepend_before_action -> { response.headers["Cache-Control"] = "no-store" }
      around_action ->(_controller, action) { Time.use_zone(Current.company.time_zone, &action) }
      rescue_from DriverOperationSync::Unauthorized, with: -> { render json: { error: "account_changed" }, status: :forbidden }
      rescue_from DriverOperationSync::ReusedIdentifier, with: ->(error) { render json: { error: error.message }, status: :conflict }
      rescue_from DeliveryEvidence::MissingUpload, with: ->(error) { render json: { error: error.message }, status: :service_unavailable }
      rescue_from ArgumentError, KeyError, with: ->(error) { render json: { error: error.message }, status: :unprocessable_entity }

      def work
        DriverWorkSnapshot.consistent_read do
          etag = %Q("#{Current.driver_work_revision}")
          response.headers["ETag"] = etag
          response.headers["X-Driver-Account"] = "#{Current.company.id}:#{Current.user.id}"
          response.headers["X-Driver-Work-Version"] = "4"
          response.headers["X-CSRF-Token"] = form_authenticity_token
          if request.headers["If-None-Match"].to_s.split(",").map(&:strip).include?(etag)
            head :not_modified
            next
          end
          load_dashboard(run_id: nil)
          runs = @runs.presence || [ nil ]
          packages = runs.map do |run|
            load_dashboard(run_id: run&.id)
            { id: run&.id || "empty", scheduled_date: run&.scheduled_date, name: run&.name,
              revision: DriverWorkSnapshot.package_revision(run: @run, runs: @runs, visits: @visits, date: @today),
              visits: @visits.map { |visit| serialize_visit(visit) },
              html: render_to_string(template: "repartidor/index", formats: [ :html ], layout: false) }
          end
          # Older clients must refresh before handling independent timing
          # operations. Their queued confirmations and files remain accepted.
          render json: { version: 4, account: account, csrf_token: form_authenticity_token,
            downloaded_at: Time.current.iso8601, packages: packages }
        end
      end

      def create
        attributes = params.expect(operation: [ :operation_id, :visit_id, :operation_type, :checkpoint, :occurred_at, :status, :notes, :recorded_at, :proof, :receipt_version, :failure_reason, :receiver_name,
          location: [ :latitude, :longitude, :accuracy, :captured_at ], evidence: [ [ :id, :kind, :sha256 ] ], items: [ [ :id, :delivered_quantity ] ] ]).to_h.deep_symbolize_keys
        raise ArgumentError, "Operación demasiado grande" if attributes.to_json.bytesize > 100_000
        operation = DriverOperationSync.call(user: Current.user, attributes: attributes)
        render json: operation.response_data
      end

      def show
        operation = Current.company.driver_sync_operations.where(user_id: Current.user.id).find_by!(operation_id: params[:id])
        render json: operation.response_data
      end

      private

      def request_authentication
        render json: { error: "authentication_required" }, status: :unauthorized
      end

      def require_api_driver
        render json: { error: "driver_required" }, status: :forbidden unless Current.user.driver?
      end

      def account
        { company_id: Current.company.id, user_id: Current.user.id }
      end

      def serialize_visit(visit)
        { id: visit.id, position: visit.position, status: visit.status, customer_name: visit.customer_name,
          customer_address: visit.customer_address, phone: visit.customer.phone,
          latitude: visit.current_customer_location? ? visit.customer.latitude : nil, longitude: visit.current_customer_location? ? visit.customer.longitude : nil,
          revision: DriverWorkSnapshot.revision(visit), proof: DriverWorkSnapshot.issue(user: Current.user, visit: visit),
          items: visit.delivery_items.sort_by(&:id).map { |item| item.attributes.slice("id", "product_id", "description", "unit", "planned_quantity", "delivered_quantity") } }
      end
    end
  end
end
