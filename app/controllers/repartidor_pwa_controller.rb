class RepartidorPwaController < ActionController::Base
  # A service worker is a public script fetched without an XHR header.
  skip_forgery_protection only: :service_worker

  def manifest
    render template: "pwa/manifest", formats: [ :json ], layout: false, content_type: "application/manifest+json"
  end

  def service_worker
    @asset_urls = JSON.parse(Rails.application.importmap.to_json(resolver: helpers)).fetch("imports").values
    @asset_urls += %w[repartidor.css leaflet.css plus-jakarta-sans.ttf].map { |asset| helpers.asset_path(asset) }
    @asset_urls = @asset_urls.uniq.select { |url| url.start_with?("/assets/") }
    @cache_version = Digest::SHA256.hexdigest((@asset_urls + %w[app/views/pwa/shell.html.erb app/views/pwa/service-worker.js.erb app/views/layouts/repartidor.html.erb].map { |path| Rails.root.join(path).read }).join)[0, 16]
    response.headers["Service-Worker-Allowed"] = "/repartidor"
    response.headers["Cache-Control"] = "no-cache"
    render template: "pwa/service-worker", formats: [ :js ], layout: false, content_type: "application/javascript"
  end

  def shell
    @public_shell = true
    response.headers["Cache-Control"] = "no-cache"
    render template: "pwa/shell", layout: "repartidor"
  end
end
