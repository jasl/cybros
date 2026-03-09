require "test_helper"

class ConversationAgentProgramSelectionTest < ActionDispatch::IntegrationTest
  test "switching the conversation agent updates the program without clearing unrelated config namespaces" do
    user = sign_in_owner!
    previous_program = create_program!(name: "Review agent", config_namespace: "fixture.review")
    activate_program!(previous_program)
    next_program = create_program!(name: "Builder agent", config_namespace: "fixture.builder")
    activate_program!(next_program)

    conversation = create_conversation!(user: user, title: "Chat")
    conversation.update!(
      agent_program: previous_program,
      agent_config_schema_fingerprint: previous_program.config_schema_fingerprint,
      agent_config: {
        previous_program.config_namespace => { "mode" => "review" },
        next_program.config_namespace => { "mode" => "builder" },
      },
    )

    patch conversation_path(conversation), params: { conversation: { agent_program_id: next_program.id } }

    assert_redirected_to conversation_path(conversation)
    conversation.reload

    assert_equal next_program.id, conversation.agent_program_id
    assert_equal next_program.config_schema_fingerprint, conversation.agent_config_schema_fingerprint
    assert_equal({ "mode" => "builder" }, conversation.selected_agent_config)
    assert_equal(
      {
        previous_program.config_namespace => { "mode" => "review" },
        next_program.config_namespace => { "mode" => "builder" },
      },
      conversation.agent_config,
    )
  end

  test "show warns when the selected program no longer has an active healthy deployment" do
    user = sign_in_owner!
    healthy_program = create_program!(name: "Healthy agent", config_namespace: "fixture.healthy")
    activate_program!(healthy_program)
    stale_program = create_program!(name: "Stale agent", config_namespace: "fixture.stale")
    register_deployment!(stale_program, status: "inactive", health_status: "unhealthy")

    conversation = create_conversation!(user: user, title: "Chat")
    conversation.update!(agent_program: stale_program, agent_config_schema_fingerprint: stale_program.config_schema_fingerprint)

    get conversation_path(conversation)

    assert_response :success
    assert_includes response.body, "Selected agent has no active healthy deployment. Future runs will stay blocked until you choose another agent or the operator restores this deployment."
    assert_select 'select[name="conversation[agent_program_id]"] option[selected]', text: stale_program.name
    assert_select 'select[name="conversation[agent_program_id]"] option', text: healthy_program.name
  end

  test "rejects selecting a program that is not currently active and healthy" do
    user = sign_in_owner!
    healthy_program = create_program!(name: "Healthy agent", config_namespace: "fixture.healthy")
    activate_program!(healthy_program)
    stale_program = create_program!(name: "Stale agent", config_namespace: "fixture.stale")
    register_deployment!(stale_program, status: "inactive", health_status: "unhealthy")

    conversation = create_conversation!(user: user, title: "Chat")
    conversation.update!(agent_program: healthy_program, agent_config_schema_fingerprint: healthy_program.config_schema_fingerprint)

    patch conversation_path(conversation), params: { conversation: { agent_program_id: stale_program.id } }

    assert_response :unprocessable_entity
    assert_equal healthy_program.id, conversation.reload.agent_program_id
  end

  test "builtin fallback runs do not add a selectable programmable agent" do
    user = sign_in_owner!
    healthy_program = create_program!(name: "Healthy agent", config_namespace: "fixture.healthy")
    activate_program!(healthy_program)
    conversation = create_conversation!(user: user, title: "Chat")
    ensure_active_openai_credential!

    conversation.append_user_message!(content: "Hello", model_ref: "openai/gpt-5.4")

    get conversation_path(conversation)

    assert_response :success
    assert_select 'select[name="conversation[agent_program_id]"] option', text: healthy_program.name
    assert_select 'select[name="conversation[agent_program_id]"] option', text: "Built-in Agent", count: 0
  end

  private

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

    def create_program!(name:, config_namespace:)
      AgentProgram.create!(
        name: name,
        config_namespace: config_namespace,
        published_contract_fingerprint: "contract:#{config_namespace}",
        manifest_snapshot: { "name" => name, "agent_program_key" => config_namespace.tr(".", "-") },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{config_namespace}",
      )
    end

    def activate_program!(program)
      register_deployment!(program, status: "active", health_status: "healthy")
    end

    def register_deployment!(program, status:, health_status:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "https://example.test/#{program.id}",
        deployment_bearer_secret_ref: "secret://#{program.id}",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "deployment:#{program.id}:#{status}:#{health_status}",
        status: status,
        health_status: health_status,
        protocol_version: "agent_rpc.v1",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end

    def ensure_active_openai_credential!
      credential = LLMProviderCredential.find_or_initialize_by(provider_key: "openai", status: "active")
      credential.assign_attributes(
        credential_type: "api_key",
        api_key: "sk-test",
        max_concurrent_requests: 3,
        requests_per_minute: 90,
        tokens_per_minute: 180_000,
        burst_limit: 6,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10_000 },
      )
      credential.save!
      credential
    end
end
