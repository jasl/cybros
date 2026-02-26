# frozen_string_literal: true

require "test_helper"

class SetupAndSessionsTest < ActionDispatch::IntegrationTest
  test "root redirects to setup when no identities exist" do
    Identity.delete_all

    get root_path
    assert_redirected_to new_setup_path
  end

  test "setup wizard creates initial identity and signs in" do
    Identity.delete_all
    Session.delete_all

    get new_setup_path
    assert_response :success

    assert_difference -> { Identity.count }, +1 do
      assert_difference -> { User.count }, +1 do
        assert_difference -> { Session.count }, +1 do
          post setup_path, params: {
            identity: {
              email: "admin@example.com",
              password: "Passw0rd",
              password_confirmation: "Passw0rd",
            },
          }
        end
      end
    end

    assert_redirected_to root_path
    assert cookies[:session_token].present?

    follow_redirect!
    assert_response :success
  end

  test "setup wizard is not accessible after initial identity exists" do
    Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")

    get new_setup_path
    assert_redirected_to root_path
  end

  test "sessions new redirects to setup when no identities exist" do
    Identity.delete_all

    get new_session_path
    assert_redirected_to new_setup_path
  end

  test "sessions create authenticates with email and password and sets cookie" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "sessions create with invalid credentials re-renders and does not set cookie" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "wrong" }
    assert_response :unprocessable_entity
    assert_not cookies[:session_token].present?
  end

  test "sessions destroy clears cookie" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert cookies[:session_token].present?

    delete session_path
    assert_redirected_to new_session_path
    assert_not cookies[:session_token].present?
  end
end

