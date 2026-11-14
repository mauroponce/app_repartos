class RepartidorPwaController < ActionController::Base
  # A service worker is a public script fetched without an XHR header.
  skip_forgery_protection only: :service_worker

  def manifest
    render template: "pwa/manifest", formats: [ :json ], layout: false, content_type: "application/manifest+json"
  end

  def service_worker
    response.headers["Service-Worker-Allowed"] = "/repartidor"
    response.headers["Cache-Control"] = "no-cache"
    render template: "pwa/service-worker", formats: [ :js ], layout: false, content_type: "application/javascript"
  end
end
