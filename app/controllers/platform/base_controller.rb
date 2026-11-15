module Platform
  class BaseController < ApplicationController
    allow_unauthenticated_access
    before_action :require_platform_admin
    layout "platform"

    private

    def require_platform_admin
      response.headers["Cache-Control"] = "no-store"
      Current.platform_session = PlatformSession.active.find_by(id: cookies.signed[:platform_session_id])
      redirect_to new_platform_session_path unless Current.platform_session
    end
  end
end
