require "test_helper"

class UiSmokeTest < ActionDispatch::IntegrationTest
  setup do
    LLMProviderCredential.delete_all
  end

  def sign_in!(user: nil, password: "Passw0rd")
    user ||= create_user!(role: :owner, password: password)
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
    user
  end

  test "unauthenticated home loads" do
    get root_path
    # Root may render publicly once an owner exists, but a fresh install redirects to setup.
    if Identity.exists?
      assert_response :success
    else
      assert_redirected_to new_setup_path
    end
  end

  test "authenticated top-level pages load" do
    sign_in!
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")
    default_agent = Agents::BootstrapBundledDefaultService.ensure_agent!

    get dashboard_path
    assert_response :success

    get conversations_path
    assert_response :success

    post conversations_path, params: { conversation: { agent_id: default_agent.id } }
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Message…"

    get settings_profile_path
    assert_response :success

    get settings_sessions_path
    assert_response :success

    get system_settings_llm_providers_path
    assert_response :success

    get dashboard_path
    assert_response :success
  end
end
