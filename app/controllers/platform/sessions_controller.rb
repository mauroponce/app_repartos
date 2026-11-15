module Platform
  class SessionsController < BaseController
    skip_before_action :require_platform_admin, only: %i[new create]
    layout "authentication"
    rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_platform_session_path, alert: "Demasiados intentos. Volvé a intentar en unos minutos." }

    def new
      response.headers["Cache-Control"] = "no-store"
    end

    def create
      admin = PlatformAdmin.authenticate_by(params.permit(:email_address, :password))
      if admin
        PlatformSession.find_by(id: cookies.signed[:platform_session_id])&.destroy!
        reset_session
        platform_session = admin.platform_sessions.create!(ip_address: request.remote_ip, user_agent: request.user_agent, expires_at: 12.hours.from_now)
        cookies.signed[:platform_session_id] = { value: platform_session.id, httponly: true, same_site: :lax,
          secure: Rails.env.production?, path: "/plataforma", expires: platform_session.expires_at }
        redirect_to platform_root_path, status: :see_other
      else
        redirect_to new_platform_session_path, alert: "El email o la contraseña son incorrectos.", status: :see_other
      end
    end

    def destroy
      Current.platform_session.destroy!
      Current.platform_session = nil
      cookies.delete(:platform_session_id, path: "/plataforma")
      reset_session
      redirect_to new_platform_session_path, status: :see_other
    end
  end
end
