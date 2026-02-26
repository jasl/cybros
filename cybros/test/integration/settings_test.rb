require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    identity
  end

  test "profile requires authentication" do
    get settings_profile_path
    assert_redirected_to new_session_path
  end

  test "profile update changes email with current password" do
    identity = sign_in_owner!

    patch settings_profile_path, params: {
      identity: {
        email: "new@example.com",
        current_password: "Passw0rd",
      },
    }

    assert_redirected_to settings_profile_path
    assert_equal "new@example.com", identity.reload.email
  end

  test "profile update rejects invalid current password" do
    identity = sign_in_owner!

    patch settings_profile_path, params: {
      identity: {
        email: "new@example.com",
        current_password: "wrong",
      },
    }

    assert_response :unprocessable_entity
    assert_equal "admin@example.com", identity.reload.email
  end

  test "profile update changes password with current password" do
    identity = sign_in_owner!

    patch settings_profile_path, params: {
      identity: {
        current_password: "Passw0rd",
        password: "NewPassw0rd",
        password_confirmation: "NewPassw0rd",
      },
    }

    assert_redirected_to settings_profile_path
    assert identity.reload.authenticate("NewPassw0rd")
  end

  test "sessions destroy signs out all sessions" do
    identity = sign_in_owner!

    assert_equal 1, identity.sessions.count

    delete settings_sessions_path
    assert_redirected_to new_session_path
    assert_not cookies[:session_token].present?
    assert_equal 0, identity.sessions.count
  end
end
