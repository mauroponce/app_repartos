class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  layout "authentication"
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Intentaste ingresar demasiadas veces. Volvé a intentar en unos minutos." }

  def new
  end

  def create
    user = User.authenticate_by(params.permit(:email_address, :password))
    if user&.active?
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "El email o la contraseña son incorrectos."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
