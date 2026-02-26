class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern unless Rails.env.test?

  before_action :set_current_request_context
  before_action :ensure_account
  before_action :resume_session

  private
    def set_current_request_context
      Current.http_method = request.method
      Current.request_id = request.uuid
      Current.user_agent = request.user_agent
      Current.ip_address = request.remote_ip
      Current.referrer = request.referrer
    end

    def ensure_account
      Current.account = Account.instance
    end

    def resume_session
      token = cookies.signed[:session_token]
      return if token.blank?

      session = Session.find_by(id: token)
      return if session.nil?

      Current.session = session
      session.touch(:last_seen_at)
    end

    def authenticated?
      Current.identity.present?
    end

    def require_authentication
      redirect_to new_session_path unless authenticated?
    end
end
