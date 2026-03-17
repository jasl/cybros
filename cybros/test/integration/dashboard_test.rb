require "test_helper"

class DashboardTest < ActionDispatch::IntegrationTest
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

  test "dashboard renders status cards and recent conversations" do
    user = sign_in_owner!
    create_conversation!(user: user, title: "Hello")

    get dashboard_path
    assert_response :success
    assert_includes response.body, 'data-layout="agent"'
    assert_includes response.body, 'data-testid="dashboard-page"'
    assert_includes response.body, "Dashboard"
    assert_includes response.body, "Recent conversations"
    refute_includes response.body, "Dashboard content will be filled in next."
  end

  test "dashboard lists selectable agents with per-agent launchers and no generic new chat button" do
    sign_in_owner!
    custom_agent = create_selectable_agent!(name: "Research agent")

    get dashboard_path
    assert_response :success

    assert_includes response.body, custom_agent.name
    assert_select 'input[name="conversation[agent_id]"][value=?]', custom_agent.id
    assert_select 'button[type="submit"]', text: "New conversation"
    refute_includes response.body, "New chat"
  end

  test "dashboard launcher creates a conversation bound to the selected agent" do
    user = sign_in_owner!
    custom_agent = create_selectable_agent!(name: "Research agent")

    assert_difference -> { Conversation.count }, +1 do
      post conversations_path, params: { conversation: { title: "Launched", agent_id: custom_agent.id } }
    end

    conversation = Conversation.order(:created_at).last

    assert_redirected_to conversation_path(conversation)
    assert_equal user.id, conversation.user_id
    assert_equal custom_agent.id, conversation.agent_id
  end

  test "dashboard only shows current user's conversations" do
    user_a = sign_in_owner!
    create_conversation!(user: user_a, title: "My Chat")

    user_b = create_user!
    create_conversation!(user: user_b, title: "Other Chat")

    get dashboard_path
    assert_response :success
    assert_includes response.body, "My Chat"
    refute_includes response.body, "Other Chat"
  end

  private

    def create_selectable_agent!(name:)
      program =
        create_agent_record!(
          name: name,
          config_namespace: "fixture.dashboard.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_key" => SecureRandom.hex(4), "name" => name },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-#{SecureRandom.hex(4)}",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
      materialize_agent_runtime!(program: program, execution_target: build_default_execution_profile!)
    end
end
