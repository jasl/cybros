require "test_helper"

class RecognizedDeploymentDriftTest < ActiveSupport::TestCase
  test "reply unknown replay fails safe when initialize resolves a different recognized deployment" do
    primary_server = fixture_server!.start
    drifted_server =
      fixture_server!(
        identity_overrides: {
          "supported_methods" => Agents::Protocol::REQUIRED_METHODS + ["attachments.import"],
        },
      ).start
    runtime = create_runtime!(endpoint_url: primary_server.rpc_url)
    draft = create_run_draft!(runtime:)

    invocation =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: draft.id,
        method_name: "before_agent_step",
        invocation_id: "invoke-drifted-replay",
        request_payload: { "user_input" => "Hello" },
      ).fetch(:invocation)
    AgentRPC::InvocationStore.mark_reply_unknown!(
      invocation: invocation,
      error_snapshot: { "message" => "lost reply", "kind" => "lost_reply" },
    )
    runtime.fetch(:deployment).update!(endpoint_url: drifted_server.rpc_url)
    sync_agent_runtime_from_binding!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

    remote_call_count = 0
    error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::LifecycleCaller.call!(
          deployment: runtime.fetch(:deployment).reload,
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: draft.id,
          method_name: "before_agent_step",
          invocation_id: "invoke-drifted-replay",
          request_payload: { "user_input" => "Hello" },
          allowed_callback_methods: %w[conversation.settings.get],
          rpc_client_factory: lambda do |**_kwargs|
            remote_call_count += 1
            raise "remote client should not be constructed after recognized deployment drift"
          end,
        )
      end

    assert_equal "cybros.agent_rpc.recognized_deployment_drift", error.code
    assert_equal 0, remote_call_count
    assert_equal "failed", invocation.reload.status
    assert_equal "cybros.agent_rpc.recognized_deployment_drift", invocation.error_snapshot.fetch("code")
    assert_equal 0, AgentRPCSession.where(agent_rpc_invocation: invocation).count
  ensure
    primary_server&.shutdown
    drifted_server&.shutdown
  end

  test "callback authorization closes the session when initialize resolves a different recognized deployment" do
    primary_server = fixture_server!.start
    drifted_server =
      fixture_server!(
        identity_overrides: {
          "agent_sdk_version" => "fixture-ruby-sdk/2.0",
        },
      ).start
    runtime = create_runtime!(endpoint_url: primary_server.rpc_url)

    opened =
      AgentRPC::SessionAuthorizer.open!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        allowed_methods: %w[conversation.settings.get],
      )
    session = opened.fetch(:session)
    runtime.fetch(:deployment).update!(endpoint_url: drifted_server.rpc_url)
    sync_agent_runtime_from_binding!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

    error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::SessionAuthorizer.authorize_callback!(
          bearer: opened.fetch(:session_bearer),
          method_name: "conversation.settings.get",
          scope_type: session.scope_type,
          scope_id: session.scope_id,
        )
      end

    assert_equal "cybros.agent_rpc.recognized_deployment_drift", error.code
    assert_equal "closed", session.reload.status
  ensure
    primary_server&.shutdown
    drifted_server&.shutdown
  end

  test "reply unknown replay fails safe when only the transport endpoint changes in place" do
    primary_server = fixture_server!.start
    replacement_server = fixture_server!.start
    runtime = create_runtime!(endpoint_url: primary_server.rpc_url)
    draft = create_run_draft!(runtime:)

    invocation =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: draft.id,
        method_name: "before_agent_step",
        invocation_id: "invoke-transport-retarget",
        request_payload: { "user_input" => "Hello" },
      ).fetch(:invocation)
    AgentRPC::InvocationStore.mark_reply_unknown!(
      invocation: invocation,
      error_snapshot: { "message" => "lost reply", "kind" => "lost_reply" },
    )
    runtime.fetch(:deployment).update!(endpoint_url: replacement_server.rpc_url)
    sync_agent_runtime_from_binding!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

    remote_call_count = 0
    error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::LifecycleCaller.call!(
          deployment: runtime.fetch(:deployment).reload,
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: draft.id,
          method_name: "before_agent_step",
          invocation_id: "invoke-transport-retarget",
          request_payload: { "user_input" => "Hello" },
          allowed_callback_methods: %w[conversation.settings.get],
          rpc_client_factory: lambda do |**_kwargs|
            remote_call_count += 1
            raise "remote client should not be constructed after recognized deployment drift"
          end,
        )
      end

    assert_equal "cybros.agent_rpc.recognized_deployment_drift", error.code
    assert_equal 0, remote_call_count
    assert_equal "failed", invocation.reload.status
  ensure
    primary_server&.shutdown
    replacement_server&.shutdown
  end

  test "callback authorization closes the session when only the transport endpoint changes in place" do
    primary_server = fixture_server!.start
    replacement_server = fixture_server!.start
    runtime = create_runtime!(endpoint_url: primary_server.rpc_url)

    opened =
      AgentRPC::SessionAuthorizer.open!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        allowed_methods: %w[conversation.settings.get],
      )
    session = opened.fetch(:session)
    runtime.fetch(:deployment).update!(endpoint_url: replacement_server.rpc_url)
    sync_agent_runtime_from_binding!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

    error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::SessionAuthorizer.authorize_callback!(
          bearer: opened.fetch(:session_bearer),
          method_name: "conversation.settings.get",
          scope_type: session.scope_type,
          scope_id: session.scope_id,
        )
      end

    assert_equal "cybros.agent_rpc.recognized_deployment_drift", error.code
    assert_equal "closed", session.reload.status
  ensure
    primary_server&.shutdown
    replacement_server&.shutdown
  end

  private

    def fixture_server!(identity_overrides: {})
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: identity_overrides,
      )
    end

    def create_runtime!(endpoint_url:)
      program =
        create_agent_record!(
          name: "Fixture Program",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_key" => "fixture-program", "name" => "Fixture Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      target = build_default_execution_profile!
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      deployment =
        create_runtime_binding_record!(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: "contract:v1",
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS,
          manifest_snapshot: program.manifest_snapshot,
          schema_snapshot: {},
          capability_snapshot: { "agent_capabilities_version" => "2026-03-13" },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      conversation =
        create_conversation!(
          agent: agent,
          agent_program: program,
          default_execution_target: target,
        )

      {
        agent: agent,
        conversation: conversation,
        deployment: deployment,
        program: program,
        recognized_deployment: recognized_deployment,
        target: target,
      }
    end

    def create_run_draft!(runtime:)
      RunDraft.create!(
        conversation: runtime.fetch(:conversation),
        initiated_by_user: runtime.fetch(:conversation).user,
        status: "prepared",
        permission_mode: "default",
        trigger_snapshot: { "kind" => "user_turn", "dag_node_id" => SecureRandom.uuid, "user_input" => "Hello" },
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        recognized_deployment_key: runtime.fetch(:recognized_deployment).recognized_deployment_key,
        contract_fingerprint: runtime.fetch(:program).published_contract_fingerprint,
        deployment_fingerprint: runtime.fetch(:deployment).deployment_fingerprint,
        deployment_activated_at: runtime.fetch(:deployment).activated_at,
        runtime_governors: {
          "execution_capacity" => RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: runtime.fetch(:agent)),
        },
        agent_config_schema_fingerprint: runtime.fetch(:agent).config_schema_fingerprint,
        prepare_invocation_id: SecureRandom.uuid,
        planning: {},
        staged_public_settings_patch: {},
        staged_agent_config_patch: {},
        staged_kv_ops: [],
        staged_prompt_buffer_ops: [],
        approval_state: { "status" => "not_required" },
        expires_at: 30.minutes.from_now.change(usec: 0),
      ).tap do |draft|
        assert_nil draft[:agent_program_id]
        assert_nil draft[:agent_deployment_id]
      end
    end
end
