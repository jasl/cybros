module Settings
  class SessionsController < BaseController
    def show
      @sessions = Current.identity.sessions.order(last_seen_at: :desc, created_at: :desc)
    end

    def destroy
      Current.identity.sessions.destroy_all
      Current.session = nil
      cookies.delete(:session_token)
      redirect_to new_session_path
    end
  end
end
