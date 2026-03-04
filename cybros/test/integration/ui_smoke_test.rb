require "test_helper"

class UiSmokeTest < ActionDispatch::IntegrationTest
  def sign_in!(user: nil, password: "Passw0rd")
    user ||= create_user!(role: :owner, password: password)
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
    user
  end

  test "unauthenticated home loads" do
    get root_path
    assert_response :success
  end

  test "authenticated top-level pages load" do
    sign_in!

    get dashboard_path
    assert_response :success

    get conversations_path
    assert_response :success

    post conversations_path
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Message…"

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

