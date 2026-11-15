class DriverOperationSync
  class Unauthorized < StandardError; end
  class ReusedIdentifier < StandardError; end

  def self.call(user:, attributes:)
    id = attributes.fetch(:operation_id).to_s.downcase
    raise ArgumentError, "UUID de operación inválido" unless id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
    payload = attributes.slice(:visit_id, :status, :notes, :items, :recorded_at, :proof, :receipt_version, :failure_reason, :receiver_name, :location, :evidence, :operation_type, :checkpoint, :occurred_at).deep_stringify_keys
    digest = Digest::SHA256.hexdigest(payload.to_json)
    user.company.with_lock do
      # Recheck under the same lock used for reassignment and execution.
      raise Unauthorized unless user.reload.active? && user.driver?
      records = user.company.driver_sync_operations.where(user_id: user.id)
      if (existing = records.find_by(operation_id: id))
        raise ReusedIdentifier, "El UUID ya corresponde a otro contenido; conservá ambos registros para revisión" unless existing.payload_digest == digest
        return existing
      end
      proof = DriverWorkSnapshot.read(payload["proof"])
      raise Unauthorized unless proof && proof["company_id"] == user.company_id && proof["user_id"] == user.id
      raise Unauthorized unless proof["visit_id"].to_s == payload["visit_id"].to_s
      evidences = DeliveryEvidence.resolve_manifest!(user: user, operation_id: id, visit_id: payload["visit_id"], manifest: payload["evidence"])
      operation = records.new(user: user, operation_id: id, visit_id: payload["visit_id"],
        payload: payload.merge("download_snapshot" => proof["snapshot"]), payload_digest: digest, status: :conflict)
      operation.recorded_at = Time.iso8601(payload["recorded_at"].to_s) rescue nil
      # A savepoint rolls back every item if validation of a later item fails.
      begin
        ApplicationRecord.transaction(requires_new: true) do
          visit = AuditContext.set(user: user, source: "offline", operation_id: id) do
            if payload["operation_type"] == "visit_checkpoint"
              raise ArgumentError, "Un horario no admite evidencias" if evidences.any?
              DriverVisitCheckpointRecorder.call(user: user, visit_id: payload["visit_id"], checkpoint: payload["checkpoint"], occurred_at: payload["occurred_at"], offline_proof: proof)
            elsif payload["operation_type"].blank? || payload["operation_type"] == "visit_confirmation"
              DriverVisitRecorder.call(user: user, visit_id: payload["visit_id"], attributes: payload.deep_symbolize_keys, offline_proof: proof)
            else
              raise ArgumentError, "Tipo de operación inválido"
            end
          end
          operation.status = :synced
          operation.result = { visit_id: visit.id, visit_status: visit.status, confirmed_at: visit.confirmed_at,
            evidence_ids: evidences.map(&:evidence_uuid),
            checkpoint: payload["operation_type"] == "visit_checkpoint" ? payload["checkpoint"] : nil,
            occurred_at: payload["operation_type"] == "visit_checkpoint" ? visit.attributes[payload["checkpoint"]] : nil,
            orders: visit.delivery_orders.map { |order| { id: order.id, status: order.status, fulfillment: order.fulfillment_result } } }
        end
      rescue ActiveRecord::RecordNotFound
        operation.result = { code: "visit_unavailable", message: "La visita ya no está disponible para este repartidor. Administración debe revisar el intento." }
      rescue DriverVisitRecorder::Conflict => error
        operation.result = { code: "business_conflict", message: error.message }
      rescue ArgumentError, KeyError, ActiveRecord::RecordInvalid => error
        operation.status = :invalid
        operation.result = { code: "validation_error", message: error.message }
      end
      operation.save!
      evidences.each { |evidence| evidence.update!(driver_sync_operation: operation) }
      operation
    end
  end
end
