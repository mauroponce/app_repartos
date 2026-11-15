module CustomerImports
  class Workflow
    class Invalid < StandardError; end
    STATES = { "reading" => "Leyendo archivo", "mapping" => "Mapear columnas", "preparing" => "Validando filas", "processing" => "Buscando ubicaciones", "review" => "Revisar resultados", "importing" => "Creando clientes", "completed" => "Importación confirmada", "cancelled" => "Cancelada", "failed" => "Error recuperable" }.freeze

    def self.enqueue(import, action)
      CustomerImportJob.perform_later(import.company_id, import.id, import.generation, action)
    rescue StandardError
      # Maintenance recovers committed work if the queue DB is unavailable.
      import.update_columns(last_error: "No se pudo encolar. El mantenimiento reintentará automáticamente.")
    end

    def self.start!(import)
      import.with_lock do
        raise Invalid, "El lote no admite procesamiento." unless import.state == "mapping" && !import.expired?
        raise Invalid, "Mapeá nombre y dirección." unless %w[name address].all? { |field| import.mapping[field].present? }
        import.update!(geographic_context: import.geographic_context.merge("province" => import.company.province, "country" => "Argentina"), state: "preparing", last_error: nil, heartbeat_at: Time.current)
      end
      enqueue(import, "prepare")
    end

    def self.confirm!(import, acknowledge_duplicates:, acknowledge_pending:)
      import.with_lock do
        return if import.state.in?(%w[importing completed])
        raise Invalid, "El lote no está listo para confirmar." unless import.editable?
        rows = import.import_rows.where(excluded: false, customer_id: nil)
        raise Invalid, "No hay filas seleccionadas." unless rows.exists?
        raise Invalid, "Corregí u omití las filas con errores." if rows.where("issues <> '[]'::jsonb").exists?
        if rows.where("duplicates <> '[]'::jsonb").exists? && !acknowledge_duplicates
          raise Invalid, "Confirmá que revisaste los posibles duplicados. No se actualizarán clientes existentes."
        end
        if rows.where.not(review_state: %w[manual automatic]).exists? && !acknowledge_pending
          raise Invalid, "Confirmá la importación de ubicaciones pendientes. No se usarán para optimizar rutas."
        end
        import.update!(state: "importing", last_error: nil, heartbeat_at: Time.current)
      end
      enqueue(import, "commit")
    end

    def self.cancel!(import)
      import.with_lock do
        raise Invalid, "No se puede cancelar durante el alta definitiva o después de confirmar." if import.state.in?(%w[importing completed legacy])
        import.update!(summary: import.summary.merge("resume_state" => import.state), state: "cancelled", generation: import.generation + 1, heartbeat_at: Time.current)
      end
    end

    def self.resume!(import)
      import.with_lock do
        raise Invalid, "El lote no admite reanudación." unless import.state.in?(%w[cancelled failed review]) && !import.expired?
        state = import.summary["resume_state"].presence_in(%w[reading mapping preparing processing review]) || "review"
        import.update!(state: state, last_error: nil, heartbeat_at: Time.current)
      end
      action = { "reading" => "read", "preparing" => "prepare", "processing" => "process" }[import.state]
      enqueue(import, action) if action
    end
  end
end
