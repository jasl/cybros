module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_identity_id

    def connect
      token = cookies.signed[:session_token]
      reject_unauthorized_connection if token.blank?

      session = Session.find_by(id: token)
      reject_unauthorized_connection if session.nil?

      Current.session = session
      self.current_identity_id = session.identity_id
    end
  end
end
