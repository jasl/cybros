require "test_helper"

class AgentRuntimeBindingCutoverTest < ActionDispatch::IntegrationTest
  test "conversation creation binds the bundled claw agent and removes execution target selection from the UI" do
    sign_in_owner!
    Account.instance.update_llm_default_model_ref!("")
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")
    default_agent = Agents::BootstrapBundledDefaultService.ensure_agent!

    assert_difference -> { Conversation.count }, +1 do
      post conversations_path, params: { conversation: { title: "Chat", agent_id: default_agent.id } }
    end

    conversation = Conversation.order(:created_at).last

    assert_equal default_agent.id, conversation.agent_id
    assert_nil conversation[:agent_program_id]
    assert_nil conversation[:default_execution_target_id]
    get conversation_path(conversation)

    assert_response :success
    assert_select 'select[name="conversation[agent_id]"] option[selected]', text: default_agent.name
    assert_select 'select[name="conversation[default_execution_target_id]"]', count: 0
  end

  test "runtime settings updates switch agent_id without clearing unrelated config namespaces" do
    user = sign_in_owner!
    previous = create_agent_runtime!(name: "Review Agent", namespace: "fixture.review")
    current = create_agent_runtime!(name: "Builder Agent", namespace: "fixture.builder")
    conversation = create_conversation!(user: user, title: "Chat", agent: previous.fetch(:agent), agent_program: previous.fetch(:program))
    conversation.update!(
      agent_config: {
        previous.fetch(:agent).config_namespace => { "mode" => "review" },
        current.fetch(:agent).config_namespace => { "mode" => "builder" },
      },
      agent_config_schema_fingerprint: previous.fetch(:agent).config_schema_fingerprint,
    )

    patch conversation_path(conversation), params: { conversation: { agent_id: current.fetch(:agent).id } }

    assert_redirected_to conversation_path(conversation)
    conversation.reload
    assert_equal current.fetch(:agent).id, conversation.agent_id
    assert_nil conversation[:agent_program_id]
    assert_nil conversation[:default_execution_target_id]
    assert_equal current.fetch(:agent).config_schema_fingerprint, conversation.agent_config_schema_fingerprint
    assert_equal({ "mode" => "builder" }, conversation.selected_agent_config)
    assert_equal({ "mode" => "review" }, conversation.agent_config.fetch(previous.fetch(:agent).config_namespace))
  end

  test "bundled bootstrap provisions a claw agent row" do
    agent = Agents::BootstrapBundledDefaultService.bootstrap!

    assert_equal "claw", agent.bundled_agent_key
    assert_equal "bundled", agent.source_kind
    assert_predicate agent, :persisted?
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

      user
    end

    def create_agent_runtime!(name:, namespace:)
      program =
        create_agent_record!(
          name: name,
          config_namespace: "#{namespace}.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "name" => name, "agent_program_key" => namespace.tr(".", "-") },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:#{namespace}",
        )
      deployment =
        create_runtime_binding_record!(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: "https://example.test/#{program.id}",
          deployment_bearer_secret_ref: "secret://#{program.id}",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "deployment:#{program.id}",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          supported_methods: Agents::Protocol::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      location =
        create_execution_location_profile!(
          name: "#{name} host",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "#{name} workspace",
          root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "#{name} target",
          status: "active",
          sandboxed: true,
        )
      agent = materialize_agent_runtime!(program: program, execution_target: target)

      { agent: agent, deployment: deployment, program: program, target: target }
    end
end
