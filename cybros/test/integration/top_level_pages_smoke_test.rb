require "test_helper"

class TopLevelPagesSmokeTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "root redirects to setup wizard when no identities exist" do
    # Some integration tests intentionally disable transactions; ensure a clean slate.
    AgentRPCInvocation.update_all(last_session_id: nil)
    AgentRPCSession.delete_all
    AgentRPCInvocation.delete_all
    ConversationRun.delete_all
    Event.delete_all
    Conversation.delete_all
    Session.delete_all
    User.delete_all
    Identity.delete_all

    DAG::NodeEvent.delete_all
    DAG::Edge.delete_all
    DAG::Node.delete_all
    DAG::NodeBody.delete_all
    DAG::Graph.delete_all

    get root_path
    assert_redirected_to new_setup_path
  end

  test "landing page renders when unauthenticated after setup" do
    _ = create_user!(role: :owner)

    get root_path
    assert_response :success
    assert_includes response.body, 'data-layout="landing"'
    assert_includes response.body, "Sign in"
  end

  test "authenticated top-level pages load without render exceptions" do
    user = create_user!(role: :owner)
    sign_in!(user)

    get dashboard_path
    assert_response :success
    assert_includes response.body, 'data-layout="agent"'
    assert_includes response.body, 'data-testid="dashboard-page"'

    get conversations_path
    assert_response :success
    assert_includes response.body, 'data-layout="agent"'
    assert_includes response.body, "Conversations"

    get agent_programs_path
    assert_redirected_to system_settings_agent_programs_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, 'data-layout="settings"'
    assert_includes response.body, "Agent Programs"

    get settings_profile_path
    assert_response :success
    assert_includes response.body, 'data-layout="settings"'
    assert_includes response.body, "Profile"

    get system_settings_llm_providers_path
    assert_response :success
    assert_includes response.body, 'data-layout="settings"'
    assert_includes response.body, "LLM Providers"
  end

  test "authenticated pages require authentication" do
    get dashboard_path
    assert_redirected_to new_session_path

    get conversations_path
    assert_redirected_to new_session_path

    get agent_programs_path
    assert_redirected_to new_session_path

    get settings_profile_path
    assert_redirected_to new_session_path

    get system_settings_llm_providers_path
    assert_redirected_to new_session_path
  end

  test "public agent programs route is forbidden for non-operator members" do
    user = create_user!(role: :member)
    sign_in!(user)

    get agent_programs_path

    assert_response :forbidden
  end
end
