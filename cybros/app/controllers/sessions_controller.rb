class SessionsController < ApplicationController
  before_action :redirect_to_setup_if_needed
  before_action :redirect_authenticated_user, only: %i[new create]

  def new
  end

  def create
    identity = Identity.find_by("lower(email) = ?", params.fetch(:email).to_s.downcase.strip)

    unless identity&.authenticate(params.fetch(:password).to_s)
      flash.now[:alert] = "Invalid email or password"
      render :new, status: :unprocessable_entity
      return
    end

    session = Session.start!(identity: identity, ip_address: request.remote_ip, user_agent: request.user_agent)
    Current.session = session
    cookies.signed.permanent[:session_token] = { value: session.id, httponly: true, same_site: :lax }

    redirect_to root_path
  end

  def destroy
    Current.session&.destroy
    cookies.delete(:session_token)
    redirect_to new_session_path
  end

  private

    def redirect_to_setup_if_needed
      redirect_to new_setup_path if Identity.none?
    end

    def redirect_authenticated_user
      redirect_to root_path if authenticated?
    end
end
