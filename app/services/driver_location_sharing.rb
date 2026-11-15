# Consent is independent from the browser's geolocation permission. A sample
# can never enable sharing. Versions reject delayed activation/sample requests.
class DriverLocationSharing
  class Unauthorized < StandardError; end
  class StaleConsent < StandardError; end
  UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

  def self.revoke!(user)
    user.with_lock do
      revoke_locked!(user, user.location_consent_id || SecureRandom.uuid) if user.driver? || user.location_sharing_enabled? || user.location_consent_id.present?
    end
  end

  def self.revoke_locked!(user, consent_id)
    unless !user.location_sharing_enabled? && user.location_consent_id == consent_id && user.location_deactivated_at
      user.update!(location_sharing_enabled: false, location_consent_id: consent_id,
        location_consent_version: user.location_consent_version + 1, location_deactivated_at: Time.current)
    end
    user.company.driver_locations.where(user_id: user.id).each(&:destroy!)
  end

  def self.state(user)
    location = user.company.driver_locations.find_by(user_id: user.id)
    { accepted: true, sharing: user.location_sharing_enabled?, consent_id: user.location_consent_id,
      version: user.location_consent_version, captured_at: location&.captured_at&.iso8601 }
  end

  def self.call(user:, session:, attributes:)
    user.with_lock do
      unless user.active? && user.driver? && session&.user_id == user.id && user.sessions.exists?(session.id)
        raise Unauthorized, "La sesión ya no permite compartir ubicación"
      end
      command = attributes[:command].presence || (attributes[:sharing].in?([ false, "false" ]) ? "deactivate" : "sample")
      consent_id = attributes[:consent_id].to_s
      if command == "deactivate"
        consent_id = user.location_consent_id || SecureRandom.uuid if consent_id.blank?
        raise ArgumentError, "Identificador de consentimiento inválido" unless consent_id.match?(UUID)
        revoke_locked!(user, consent_id)
      else
        active = user.company.delivery_runs.where(driver_id: user.id, scheduled_date: user.company.local_date, status: %w[assigned in_progress]).exists?
        raise ArgumentError, "No hay una jornada activa" unless active
        raise ArgumentError, "Identificador de consentimiento inválido" unless consent_id.match?(UUID)
        version = Integer(attributes.fetch(:expected_version).to_s, 10)
        case command
        when "activate"
          unless user.location_sharing_enabled? && user.location_consent_id == consent_id
            raise StaleConsent, "El consentimiento cambió. Volvé a activar la ubicación voluntariamente." unless version == user.location_consent_version
            user.company.driver_locations.where(user_id: user.id).each(&:destroy!)
            user.update!(location_sharing_enabled: true, location_consent_id: consent_id,
              location_consent_version: version + 1, location_activated_at: Time.current)
          end
        when "sample"
          unless user.location_sharing_enabled? && user.location_consent_id == consent_id && user.location_consent_version == version
            raise StaleConsent, "La ubicación está desactivada o el consentimiento cambió"
          end
          captured = Time.iso8601(attributes.fetch(:captured_at).to_s)
          raise ArgumentError, "La ubicación no es reciente" unless captured.between?(5.minutes.ago, 2.minutes.from_now)
          location = user.company.driver_locations.find_or_initialize_by(user_id: user.id)
          if location.new_record? || captured > location.captured_at
            location.update!(attributes.slice(:latitude, :longitude, :accuracy).merge(captured_at: captured, sharing: true, eta_data: {}))
          end
        else raise ArgumentError, "Comando de ubicación inválido"
        end
      end
      state(user)
    end
  end
end
