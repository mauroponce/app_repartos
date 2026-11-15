require "vips"

class WorkflowPhotoUploads
  def self.prepare(files, manifest)
    files, manifest = Array(files), Array(manifest)
    raise ArgumentError, "Adjuntá hasta 4 fotografías, sin repetirlas" unless files.size == manifest.size && files.size <= 4 && manifest.map { |row| row[:id] }.uniq.size == manifest.size
    prepared = []
    files.zip(manifest).each do |upload, entry|
      raise ArgumentError, "Fotografía inválida" unless entry[:id].to_s.match?(DeliveryEvidence::UUID) && upload.respond_to?(:read) && upload.size.between?(1, 2.megabytes)
      bytes = upload.read(2.megabytes + 1)
      digest = Digest::SHA256.hexdigest(bytes)
      raise ArgumentError, "La fotografía cambió o supera 2 MB" unless bytes.bytesize <= 2.megabytes && digest == entry[:sha256]
      type = Marcel::MimeType.for(StringIO.new(bytes))
      raise ArgumentError, "Usá fotos JPEG, PNG o WebP" unless type.in?(%w[image/jpeg image/png image/webp])
      image = Vips::Image.new_from_buffer(bytes, "", access: :sequential, fail_on: :error)
      raise ArgumentError, "La imagen tiene demasiados píxeles" if image.width * image.height > 16_000_000
      sanitized = image.autorot.thumbnail_image(1600, height: 1600, size: :down).write_to_buffer(".jpg", strip: true)
      raise ArgumentError, "La imagen procesada supera 2 MB" if sanitized.bytesize > 2.megabytes
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(sanitized), filename: "#{entry[:id]}.jpg", content_type: "image/jpeg", identify: false, metadata: { analyzed: true, incident_photo: true })
      prepared << { id: entry[:id], sha256: digest, blob: blob }
    end
    prepared
  rescue StandardError => error
    prepared&.each { |row| row[:blob].purge_later if row[:blob].attachments.empty? }
    raise ArgumentError, "No se pudo leer la fotografía" if error.is_a?(Vips::Error)
    raise
  end
end
