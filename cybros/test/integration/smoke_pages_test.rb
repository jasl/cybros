require "test_helper"

class SmokePagesTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "top-level pages render" do
    user = sign_in_owner!

    get root_path
    assert_response :redirect
    follow_redirect!
    assert_response :success

    get dashboard_path
    assert_response :success

    get conversations_path
    assert_response :success

    conversation = create_conversation!(user: user, title: "Chat")
    get conversation_path(conversation)
    assert_response :success

    get agent_programs_path
    assert_response :success

    get settings_profile_path
    assert_response :success

    get settings_sessions_path
    assert_response :success

    get system_settings_llm_providers_path
    assert_response :success

    get system_settings_agent_programs_path
    assert_response :success
  end
end
