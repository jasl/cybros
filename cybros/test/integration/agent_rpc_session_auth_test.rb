require "test_helper"

class AgentRPCSessionAuthTest < ActiveSupport::TestCase
  setup do
    @fixture_servers = []
  end

  teardown do
    Array(@fixture_servers).each(&:shutdown)
  end

  test "opening a callback session verifies initialize with the deployment bearer and mints a scoped callback bearer" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_bound_runtime!(endpoint_url: server.rpc_url, deployment_bearer_secret_ref: "secret://fixture")

    opened =
      AgentRPC::SessionAuthorizer.open!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        allowed_methods: %w[conversation.settings.get lane.kv.list],
      )

    session = opened.fetch(:session)
    callback_bearer = opened.fetch(:session_bearer)
    authorized =
      AgentRPC::SessionAuthorizer.authorize_callback!(
        bearer: callback_bearer,
        method_name: "conversation.settings.get",
        scope_type: session.scope_type,
        scope_id: session.scope_id,
      )

    assert_equal session.id, authorized.id
    assert_equal runtime.fetch(:agent).id, session.agent_id
    assert_equal opened.fetch(:recognized_deployment).id, session.recognized_deployment_id
    assert_equal runtime.fetch(:conversation).id, session.conversation_id
    assert_includes session.allowed_methods, "conversation.settings.get"
    assert_predicate session.expires_at, :future?
  ensure
    server&.shutdown
  end

  test "opening a callback session rejects initialize when deployment bearer auth fails" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://expected").start
    runtime = create_bound_runtime!(endpoint_url: server.rpc_url, deployment_bearer_secret_ref: "secret://wrong")

    error = nil
    assert_no_difference -> { AgentRPCSession.count } do
      error =
        assert_raises(AgentCore::ValidationError) do
          AgentRPC::SessionAuthorizer.open!(
            deployment: runtime.fetch(:deployment),
            conversation: runtime.fetch(:conversation),
            scope_type: "run_draft",
            scope_id: SecureRandom.uuid,
            allowed_methods: %w[conversation.settings.get],
          )
        end
    end

    assert_equal "cybros.agent_rpc.deployment_auth_failed", error.code
  ensure
    server&.shutdown
  end

  test "opening a callback session resolves recognized deployment from the deployment bound agent, not an unrelated conversation agent" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_bound_runtime!(endpoint_url: server.rpc_url, deployment_bearer_secret_ref: "secret://fixture")
    conversation = create_conversation!

    opened =
      AgentRPC::SessionAuthorizer.open!(
        deployment: runtime.fetch(:deployment),
        conversation: conversation,
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        allowed_methods: %w[conversation.settings.get],
      )

    assert_equal runtime.fetch(:agent).id, opened.fetch(:recognized_deployment).agent_id
    refute_equal conversation.agent_id, opened.fetch(:recognized_deployment).agent_id
  ensure
    server&.shutdown
  end

  test "callback authorization rejects expired or disallowed session bearers" do
    session, callback_bearer = create_open_session!

    disallowed_error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::SessionAuthorizer.authorize_callback!(
          bearer: callback_bearer,
          method_name: "lane.kv.delete",
          scope_type: session.scope_type,
          scope_id: session.scope_id,
        )
      end

    assert_equal "cybros.agent_rpc.callback_method_not_allowed", disallowed_error.code

    session.update!(expires_at: 1.second.ago.change(usec: 0))

    expired_error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::SessionAuthorizer.authorize_callback!(
          bearer: callback_bearer,
          method_name: "conversation.settings.get",
          scope_type: session.scope_type,
          scope_id: session.scope_id,
        )
      end

    assert_equal "cybros.agent_rpc.callback_session_expired", expired_error.code
  end

  test "callback authorization rejects closed session bearers" do
    session, callback_bearer = create_open_session!
    session.update!(status: "closed")

    error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::SessionAuthorizer.authorize_callback!(
          bearer: callback_bearer,
          method_name: "conversation.settings.get",
          scope_type: session.scope_type,
          scope_id: session.scope_id,
        )
      end

    assert_equal "cybros.agent_rpc.callback_session_closed", error.code
  end

  test "callback authorization rejects stale deployment activations and closes the callback session" do
    session, callback_bearer = create_open_session!
    session.agent.update!(activated_at: 1.minute.from_now.change(usec: 0))

    error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::SessionAuthorizer.authorize_callback!(
          bearer: callback_bearer,
          method_name: "conversation.settings.get",
          scope_type: session.scope_type,
          scope_id: session.scope_id,
        )
      end

    assert_equal "cybros.agent_rpc.deployment_activation_drift", error.code
    assert_equal "closed", session.reload.status
  end

  test "draft planning uses bounded agent_rpc session and invocation bookkeeping" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_programmable_runtime!(endpoint_url: server.rpc_url, deployment_bearer_secret_ref: "secret://fixture")

    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: runtime.fetch(:conversation),
        initiated_by_user: runtime.fetch(:conversation).user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Ship it",
        },
      )

    invocation = AgentRPCInvocation.find_by!(invocation_id: draft.prepare_invocation_id)
    session = AgentRPCSession.find_by!(agent_rpc_invocation: invocation)

    assert_equal runtime.fetch(:agent).id, invocation.agent_id
    assert_equal draft.recognized_deployment_id, invocation.recognized_deployment_id
    assert_equal draft.id, invocation.scope_id
    assert_equal "before_agent_step", invocation.method
    assert_equal "succeeded", invocation.status
    assert_equal "closed", session.status
    assert_equal draft.id, session.scope_id
  ensure
    server&.shutdown
  end

  test "conversation run callback sessions validate tool surfaces against the pinned capability snapshot" do
    session, callback_bearer =
      create_open_session!(
        scope_type: "conversation_run",
        allowed_methods: %w[tool_surface.manifest],
        capability_snapshot: capability_snapshot_payload,
      )

    result =
      AgentRPC::CallbackDispatcher.call!(
        bearer: callback_bearer,
        method_name: "tool_surface.manifest",
        scope_type: session.scope_type,
        scope_id: session.scope_id,
        payload: {
          "execution_context" => { "conversation_id" => session.conversation_id },
          "capability_registry_snapshot_id" => capability_snapshot_payload.fetch("capability_registry_snapshot_id"),
          "selected_tool_ids" => [
            capability_snapshot_payload.fetch("effective_tools").first.fetch("effective_tool_id"),
          ],
          "tool_surface_label" => "bundled-default",
        },
      )

    assert_equal capability_snapshot_payload.fetch("capability_registry_snapshot_id"), result.fetch("capability_registry_snapshot_id")
    assert_equal ["compact_context"], result.fetch("logical_tool_names")
    assert_match(/\Asurface_/, result.fetch("tool_surface_id"))
  end

  private

    def create_programmable_runtime!(endpoint_url:, deployment_bearer_secret_ref:)
      agent =
        create_runtime_agent!(
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: deployment_bearer_secret_ref,
        )
      ensure_active_openai_credential!
      conversation = create_conversation!(agent: agent)
      recognized_deployment = recognize_agent_runtime!(agent: agent)
      conversation.update!(
        permission_mode: "default",
        agent_config_schema_fingerprint: agent.config_schema_fingerprint,
      )

      { agent: agent, conversation: conversation, deployment: agent, recognized_deployment: recognized_deployment }
    end

    def create_bound_runtime!(endpoint_url:, deployment_bearer_secret_ref:, capability_snapshot: {})
      agent =
        create_runtime_agent!(
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: deployment_bearer_secret_ref,
          capability_snapshot: capability_snapshot,
        )
      recognized_deployment = recognize_agent_runtime!(agent: agent, capability_snapshot: capability_snapshot)
      conversation = create_conversation!(agent: agent)

      {
        agent: agent,
        conversation: conversation,
        deployment: agent,
        recognized_deployment: recognized_deployment,
      }
    end

    def create_open_session!(scope_type: "run_draft", allowed_methods: %w[conversation.settings.get lane.kv.list], capability_snapshot: {})
      server = start_fixture_server!
      agent =
        create_runtime_agent!(
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          capability_snapshot: capability_snapshot,
        )
      conversation = create_conversation!
      opened =
        AgentRPC::SessionAuthorizer.open!(
          deployment: agent,
          conversation: conversation,
          scope_type: scope_type,
          scope_id: SecureRandom.uuid,
          allowed_methods: allowed_methods,
          agent: agent,
        )

      [opened.fetch(:session), opened.fetch(:session_bearer)]
    end

    def start_fixture_server!(identity_overrides: {})
      server =
        Cybros::ProgrammableAgentFixture::Server.new(
          required_bearer: "secret://fixture",
          identity_overrides: identity_overrides,
        ).start
      @fixture_servers << server
      server
    end

    def create_program!
      create_agent!(
        name: "Fixture Agent",
        config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Agent" },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_runtime_agent!(
      endpoint_url:,
      deployment_bearer_secret_ref:,
      capability_snapshot: {},
      deployment_fingerprint: "fixture-deployment-v1",
      agent_sdk_version: "fixture-ruby-sdk/1.0"
    )
      create_agent!(
        name: "Fixture Agent",
        config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        config_schema_fingerprint: "config:v1",
        manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Agent" },
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: deployment_bearer_secret_ref,
        deployment_fingerprint: deployment_fingerprint,
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: agent_sdk_version,
        supported_methods: Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
        capability_snapshot: capability_snapshot,
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
    end

    def capability_snapshot_payload
      @capability_snapshot_payload ||=
        begin
          snapshot =
            Cybros::ProgrammableAgent::CapabilitySnapshot.build(
              kernel_registry_version: "kernel:v1",
              agent_key: "fixture-program",
              agent_capabilities_version: "2026-03-11",
              kernel_tools: [
                {
                  logical_tool_name: "cybros_shell_exec",
                  implementation_ref: "kernel://cybros_shell_exec",
                },
              ],
              agent_tools: [
                {
                  logical_tool_name: "compact_context",
                  implementation_ref: "agent://compact_context",
                },
              ],
            )

          {
            "capability_registry_snapshot_id" => snapshot.snapshot_id,
            "kernel_capability_registry_version" => snapshot.kernel_registry_version,
            "agent_capabilities_version" => snapshot.agent_capabilities_version,
            "effective_tools" =>
              snapshot.effective_tools.map do |tool|
                {
                  "logical_tool_name" => tool.logical_tool_name,
                  "effective_tool_id" => tool.effective_tool_id,
                  "implementation_source" => tool.implementation_source,
                  "implementation_ref" => tool.implementation_ref,
                }
              end,
          }
        end
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
