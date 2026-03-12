require "test_helper"

class AgentRPCSessionAuthTest < ActiveSupport::TestCase
  test "opening a callback session verifies initialize with the deployment bearer and mints a scoped callback bearer" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    deployment = create_deployment!(endpoint_url: server.rpc_url, deployment_bearer_secret_ref: "secret://fixture")
    conversation = create_conversation!

    opened =
      AgentRPC::SessionAuthorizer.open!(
        deployment: deployment,
        conversation: conversation,
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        allowed_methods: %w[conversation.settings.get execution_target.list],
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
    assert_equal deployment.id, session.agent_deployment_id
    assert_equal conversation.id, session.conversation_id
    assert_includes session.allowed_methods, "conversation.settings.get"
    assert_predicate session.expires_at, :future?
  ensure
    server&.shutdown
  end

  test "opening a callback session rejects initialize when deployment bearer auth fails" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://expected").start
    deployment = create_deployment!(endpoint_url: server.rpc_url, deployment_bearer_secret_ref: "secret://wrong")
    conversation = create_conversation!

    error = nil
    assert_no_difference -> { AgentRPCSession.count } do
      error =
        assert_raises(AgentCore::ValidationError) do
          AgentRPC::SessionAuthorizer.open!(
            deployment: deployment,
            conversation: conversation,
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
    session.agent_deployment.update!(activated_at: 1.minute.from_now.change(usec: 0))

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

    assert_equal runtime.fetch(:deployment).id, invocation.agent_deployment_id
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
      conversation = create_conversation!
      program =
        AgentProgram.create!(
          name: "Fixture Program",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      deployment = create_deployment!(endpoint_url: endpoint_url, deployment_bearer_secret_ref: deployment_bearer_secret_ref, program: program)
      target = create_execution_target!
      ensure_active_openai_credential!
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
        permission_mode: "default",
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { conversation: conversation, deployment: deployment, program: program, target: target }
    end

    def create_open_session!(scope_type: "run_draft", allowed_methods: %w[conversation.settings.get execution_target.list], capability_snapshot: {})
      program = create_program!
      deployment =
        create_deployment!(
          endpoint_url: "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          program: program,
          capability_snapshot: capability_snapshot,
        )
      conversation = create_conversation!
      raw_bearer = "arpc_#{SecureRandom.hex(24)}"
      session =
        AgentRPCSession.create!(
          agent_deployment: deployment,
          agent_program: program,
          conversation: conversation,
          scope_type: scope_type,
          scope_id: SecureRandom.uuid,
          deployment_fingerprint: deployment.deployment_fingerprint,
          deployment_activated_at: deployment.activated_at,
          session_token_digest: Digest::SHA256.hexdigest(raw_bearer),
          allowed_methods: allowed_methods,
          expires_at: 5.minutes.from_now.change(usec: 0),
          status: "open",
        )

      [session, raw_bearer]
    end

    def create_program!
      AgentProgram.create!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Program" },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_deployment!(endpoint_url:, deployment_bearer_secret_ref:, program: create_program!, capability_snapshot: {})
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: deployment_bearer_secret_ref,
        contract_fingerprint: "contract:v1",
        deployment_fingerprint: "fixture-deployment-v1",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
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
              agent_program_id: "fixture-program",
              agent_program_version: "2026-03-11",
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
            "agent_capabilities_version" => snapshot.agent_program_version,
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

    def create_execution_target!
      location =
        ExecutionLocation.create!(
          name: "Primary host",
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
        Workspace.create!(
          execution_location: location,
          name: "Primary workspace",
          root_path: "/tmp/session-auth-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: "Primary target",
        status: "active",
        sandboxed: true,
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
