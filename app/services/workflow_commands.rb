class WorkflowCommands
  class Conflict < StandardError; end
  class Forbidden < StandardError; end

  def self.call(user:, operation_id:, payload:)
    raise ArgumentError, "Identificador de operación inválido" unless operation_id.to_s.match?(DeliveryEvidence::UUID)
    digest = Digest::SHA256.hexdigest(canonical(payload).to_json)
    company = user.company
    company.with_lock do
      raise Forbidden, "La cuenta no está habilitada" unless user.reload.active? && user.company_id == company.id
      existing = user.company.workflow_commands.find_by(operation_id: operation_id)
      if existing
        raise Conflict, "El identificador ya corresponde a otra operación" unless existing.user_id == user.id && existing.payload_digest == digest
        return existing.result
      end
      result = AuditContext.set(user: user, source: user.driver? ? "driver" : "manager", operation_id: operation_id) { yield }.deep_stringify_keys
      user.company.workflow_commands.create!(user: user, operation_id: operation_id, payload_digest: digest, result: result)
      result
    end
  end

  def self.canonical(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |nested| canonical(nested) }
    when Array then value.map { |nested| canonical(nested) }
    else value
    end
  end
end
