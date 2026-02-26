class SetupsController < ApplicationController
  layout "session"

  before_action :redirect_if_already_setup

  def new
    @identity = Identity.new
  end

  def create
    @identity = Identity.new(identity_params)

    unless @identity.save
      render :new, status: :unprocessable_entity
      return
    end

    User.create!(identity: @identity, role: :owner)

    session = Session.start!(identity: @identity, ip_address: request.remote_ip, user_agent: request.user_agent)
    Current.session = session
    cookies.signed.permanent[:session_token] = { value: session.id, httponly: true, same_site: :lax }

    redirect_to root_path
  end

  private

    def redirect_if_already_setup
      redirect_to root_path if Identity.exists?
    end

    def identity_params
      params.expect(identity: %i[email password password_confirmation])
    end
end
