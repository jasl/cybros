require "test_helper"

class ConversationAgentSelectionTest < ActionDispatch::IntegrationTest
  test "create rejects selecting an agent that is not currently active and healthy" do
    sign_in_owner!
    stale_agent = create_agent_runtime!(name: "Stale agent", deployment_status: "inactive", health_status: "unhealthy").fetch(:agent)

    assert_no_difference -> { Conversation.count } do
      post conversations_path, params: { conversation: { title: "Chat", agent_id: stale_agent.id } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Selected agent is not currently active and healthy."
  end

  test "show warns when the selected agent runtime is no longer active and healthy" do
    user = sign_in_owner!
    stale_agent = create_agent_runtime!(name: "Unavailable agent", deployment_status: "inactive", health_status: "unhealthy").fetch(:agent)
    conversation = create_conversation!(user: user, title: "Chat", agent: stale_agent)

    get conversation_path(conversation)

    assert_response :success
    assert_includes response.body, "Selected agent has no active healthy deployment. Future runs will stay blocked until the operator restores this deployment."
    assert_select '[data-testid="conversation-agent-stale-warning"]', count: 1
    assert_select 'select[data-testid="conversation-composer-agent-picker"]', count: 0
  end

  test "update rejects selecting an agent that is not currently active and healthy" do
    user = sign_in_owner!
    healthy_agent = create_agent_runtime!(name: "Healthy agent").fetch(:agent)
    stale_agent = create_agent_runtime!(name: "Stale agent", deployment_status: "inactive", health_status: "unhealthy").fetch(:agent)
    conversation = create_conversation!(user: user, title: "Chat", agent: healthy_agent)

    patch conversation_path(conversation), params: { conversation: { agent_id: stale_agent.id } }

    assert_response :unprocessable_entity
    assert_includes response.body, "Selected agent is not currently active and healthy."
    assert_equal healthy_agent.id, conversation.reload.agent_id
  end

  test "update rejects clearing the conversation agent selection" do
    user = sign_in_owner!
    healthy_agent = create_agent_runtime!(name: "Healthy agent").fetch(:agent)
    conversation = create_conversation!(user: user, title: "Chat", agent: healthy_agent)

    patch conversation_path(conversation), params: { conversation: { agent_id: "" } }

    assert_response :unprocessable_entity
    assert_includes response.body, "Agent selection is required."
    assert_equal healthy_agent.id, conversation.reload.agent_id
  end

  private

    def sign_in_owner!
      user = create_user!(email: "admin-#{SecureRandom.hex(4)}@example.com")
      post session_path, params: { email: user.identity.email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
      user
    end

    def create_agent_runtime!(name:, deployment_status: "active", health_status: "healthy")
      agent =
        create_agent!(
        name: name,
        config_namespace: "fixture.#{name.parameterize(separator: ".")}.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: { "name" => name },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
        transport_kind: "http_jsonrpc",
        endpoint_url: "https://example.test/#{SecureRandom.hex(4)}",
        deployment_bearer_secret_ref: "secret://#{SecureRandom.hex(4)}",
        deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
        status: deployment_status,
        health_status: health_status,
        protocol_version: "agent_rpc.v1",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        capability_snapshot: {},
        inspection_details: {},
        transport_config: {},
        activated_at: Time.current.change(usec: 0),
      )

      { agent: agent }
    end
end
