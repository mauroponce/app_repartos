require "vips"

class DeliveryEvidenceUploader
  class StorageUnavailable < StandardError; end

  def self.call(user:, attributes:)
    proof = DriverWorkSnapshot.read(attributes[:proof])
    unless user.active? && user.driver? && proof && proof["company_id"] == user.company_id && proof["user_id"] == user.id && proof["visit_id"].to_s == attributes[:visit_id].to_s
      raise DriverOperationSync::Unauthorized
    end
    kind = attributes[:kind].to_s
    raise ArgumentError, "Elegí foto o firma" unless %w[photo signature].include?(kind)
    %i[operation_id evidence_uuid].each do |key|
      raise ArgumentError, "Identificador de evidencia inválido" unless attributes[key].to_s.match?(DeliveryEvidence::UUID)
    end
    upload = attributes[:file]
    limit = kind == "photo" ? DeliveryEvidence::PHOTO_LIMIT : DeliveryEvidence::SIGNATURE_LIMIT
    raise ArgumentError, "La imagen supera el límite permitido" unless upload.respond_to?(:read) && upload.size.between?(1, limit)
    bytes = upload.read(limit + 1)
    raise ArgumentError, "La imagen supera el límite permitido" if bytes.bytesize > limit
    digest = Digest::SHA256.hexdigest(bytes)
    raise ArgumentError, "El contenido de la imagen cambió" unless digest == attributes[:sha256]
    content_type = Marcel::MimeType.for(StringIO.new(bytes))
    allowed = kind == "photo" ? %w[image/jpeg image/png image/webp] : [ "image/png" ]
    raise ArgumentError, "Usá fotos JPEG, PNG o WebP y firmas PNG" unless allowed.include?(content_type)
    image = Vips::Image.new_from_buffer(bytes, "", access: :sequential, fail_on: :error)
    raise ArgumentError, "La imagen tiene demasiados píxeles" if image.width * image.height > 16_000_000
    # Decode/re-encode to strip EXIF (including GPS) and never serve arbitrary
    # input bytes or an upload's untrusted content-type/filename.
    extension = kind == "signature" ? "png" : "jpg"
    image = image.autorot
    image = image.thumbnail_image(1600, height: 1600, size: :down) if kind == "photo"
    sanitized = image.write_to_buffer(".#{extension}", strip: true)
    raise ArgumentError, "La imagen supera el límite permitido después de procesarla" if sanitized.bytesize > limit

    record = user.company.with_lock do
      raise DriverOperationSync::Unauthorized unless user.reload.active? && user.driver?
      scope = user.company.delivery_evidences.where(user: user)
      existing = scope.find_by(evidence_uuid: attributes[:evidence_uuid])
      expected = { operation_id: attributes[:operation_id].to_s.downcase, visit_id: attributes[:visit_id].to_i, kind: kind, sha256: digest }
      if existing
        raise DriverOperationSync::ReusedIdentifier, "El identificador de evidencia ya corresponde a otro contenido" unless expected.all? { |key, value| existing.public_send(key) == value }
        existing
      else
        raise ArgumentError, "El registro ya fue confirmado; sus evidencias no se pueden cambiar" if user.company.driver_sync_operations.exists?(user: user, operation_id: attributes[:operation_id])
        pending = scope.where(operation_id: attributes[:operation_id], kind: kind)
        maximum = kind == "photo" ? DeliveryEvidence::MAX_PHOTOS : 1
        raise ArgumentError, "Se alcanzó el límite de fotos o firmas de esta visita" if pending.count >= maximum
        scope.create!(expected.merge(evidence_uuid: attributes[:evidence_uuid]))
      end
    end
    # An acknowledged operation remains idempotent after file retention expires.
    # Do not restore purged files when a device retries a lost response.
    return record if record.file.attached? || (record.driver_sync_operation_id && record.purged_at)

    # Upload to R2 outside the company lock; attach only after storage succeeds.
    blob = begin
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new(sanitized), filename: "#{record.evidence_uuid}.#{extension}",
        content_type: kind == "signature" ? "image/png" : "image/jpeg", identify: false,
        metadata: { delivery_evidence: true, analyzed: true, width: image.width, height: image.height })
    rescue StandardError => error
      Rails.logger.warn("Evidence storage upload failed: #{error.class}")
      raise StorageUnavailable, "No se pudo subir la evidencia. El dispositivo conservará los archivos y reintentará."
    end
    record.with_lock { record.file.attach(blob) unless record.file.attached? }
    blob.purge_later if record.file.blob_id != blob.id
    record
  rescue Vips::Error
    raise ArgumentError, "No se pudo leer la imagen. Elegí otra fotografía o repetí la firma."
  end
end
