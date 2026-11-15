class IncidentPhotosController < ApplicationController
  def show
    photo = Current.company.incident_photos.find(params[:id])
    unless Current.user.manages_customers? || Incident.visible_to_driver(Current.user).exists?(id: photo.incident_id)
      raise ActiveRecord::RecordNotFound
    end
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return head :gone if photo.purged_at || !photo.file.attached?
    send_data photo.file.download, type: photo.file.blob.content_type, disposition: "inline", filename: photo.file.filename.to_s
  rescue ActiveStorage::FileNotFoundError
    head :gone
  end
end
