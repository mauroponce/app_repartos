module DriverApi
  module V1
    class EvidencesController < ApplicationController
      before_action -> { response.headers["Cache-Control"] = "no-store" }

      def create
        attributes = params.expect(evidence: [ :operation_id, :visit_id, :evidence_uuid, :kind, :sha256, :proof, :file ]).to_h.symbolize_keys
        evidence = DeliveryEvidenceUploader.call(user: Current.user, attributes: attributes)
        render json: { id: evidence.evidence_uuid, sha256: evidence.sha256, uploaded: true }
      rescue DriverOperationSync::Unauthorized
        render json: { error: "Cuenta o descarga no válida" }, status: :forbidden
      rescue DriverOperationSync::ReusedIdentifier => error
        render json: { error: error.message }, status: :conflict
      rescue ArgumentError, ActiveRecord::RecordInvalid => error
        render json: { error: error.message }, status: :unprocessable_entity
      rescue DeliveryEvidenceUploader::StorageUnavailable => error
        render json: { error: error.message }, status: :service_unavailable
      end

      private

      def request_authentication
        render json: { error: "authentication_required" }, status: :unauthorized
      end
    end
  end
end
