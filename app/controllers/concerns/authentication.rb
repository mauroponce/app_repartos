module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.joins(:user).merge(User.active).find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      return_to = session.delete(:return_to_after_authenticating)
      prefix = Current.user.driver? ? "/repartidor" : "/admin"
      if return_to
        uri = URI.parse(return_to)
        return return_to if uri.host == request.host && uri.port == request.port &&
          uri.scheme == request.scheme && (uri.path == prefix || uri.path.start_with?("#{prefix}/"))
      end
      Current.user.driver? ? repartidor_root_url : admin_root_url
    rescue URI::InvalidURIError
      Current.user.driver? ? repartidor_root_url : admin_root_url
    end

    def start_new_session_for(user)
      return_to = session.delete(:return_to_after_authenticating)
      reset_session
      session[:return_to_after_authenticating] = return_to if return_to
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax, secure: Rails.env.production? }
      end
    end

    def terminate_session
      Current.session.destroy
      Current.session = nil
      reset_session
      cookies.delete(:session_id)
    end
end
