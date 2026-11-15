class DeliveryEvidencesController < ApplicationController
  before_action -> { response.headers["Cache-Control"] = "private, no-store" }
  def show
    evidence = Current.company.delivery_evidences.find(params[:id])
    raise ActiveRecord::RecordNotFound unless Current.user.manages_customers? || evidence.user_id == Current.user.id
    return head :gone if evidence.purged_at || !evidence.file.attached?
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data evidence.file.download, type: evidence.file.blob.content_type, disposition: "inline", filename: evidence.file.filename.to_s
  rescue ActiveStorage::FileNotFoundError
    head :gone
  end
end
