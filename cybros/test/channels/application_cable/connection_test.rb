# frozen_string_literal: true

require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "rejects unauthenticated connections" do
    assert_reject_connection { connect }
  end

  test "connects with a valid session cookie" do
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )
    User.create!(identity: identity, role: :owner)

    session = Session.start!(identity: identity, ip_address: "127.0.0.1", user_agent: "Test")
    cookies.signed[:session_token] = session.id

    connect

    assert_equal identity.id, connection.current_identity_id
  end
end

