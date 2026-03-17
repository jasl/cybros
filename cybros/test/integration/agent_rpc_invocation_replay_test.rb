require "test_helper"

class AgentRPCInvocationReplayTest < ActiveSupport::TestCase
  test "replays the same invocation id only against the same pinned deployment row" do
    runtime = create_runtime!
    first =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    AgentRPC::InvocationStore.mark_succeeded!(
      invocation: first.fetch(:invocation),
      result_snapshot: { "planning" => { "step_plan" => { "fixture" => true } } },
    )

    replay =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    assert_equal true, replay.fetch(:replayed)
    assert_equal first.fetch(:invocation).id, replay.fetch(:invocation).id
  end

  test "replays across a different deployment row when the recognized deployment binding is unchanged" do
    runtime = create_runtime!
    first =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    replacement =
      replacement_deployment!(
        program: runtime.fetch(:program),
        deployment_fingerprint: runtime.fetch(:deployment).deployment_fingerprint,
        activated_at: runtime.fetch(:deployment).activated_at,
      )

    second =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: replacement,
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    assert_equal true, second.fetch(:replayed)
    assert_equal first.fetch(:invocation).id, second.fetch(:invocation).id
  end

  test "does not replay across a reactivation of the same deployment row" do
    runtime = create_runtime!
    first =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )
    AgentRPC::InvocationStore.mark_succeeded!(
      invocation: first.fetch(:invocation),
      result_snapshot: { "planning" => { "step_plan" => { "fixture" => true } } },
    )

    reactivated_at = 2.minutes.from_now.change(usec: 0)
    runtime.fetch(:deployment).update!(activated_at: reactivated_at)

    replay =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment).reload,
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    assert_equal false, replay.fetch(:replayed)
    refute_equal first.fetch(:invocation).id, replay.fetch(:invocation).id
    assert_equal reactivated_at, replay.fetch(:invocation).deployment_activated_at
  end

  test "deduplicates operation ids across replayed sessions for the same invocation" do
    runtime = create_runtime!
    invocation =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      ).fetch(:invocation)

    first_session =
      create_session!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        invocation: invocation,
      )
    replay_session =
      create_session!(
        agent: runtime.fetch(:agent),
        recognized_deployment: runtime.fetch(:recognized_deployment),
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        invocation: invocation,
      )

    first =
      AgentRPC::OperationReceiptStore.record_or_replay!(
        invocation: invocation,
        session: first_session,
        operation_id: "operation-123",
        method_name: "conversation.settings.update",
        payload: { "tone" => "concise" },
        status: "applied",
        response_snapshot: { "ok" => true },
      )
    replay =
      AgentRPC::OperationReceiptStore.record_or_replay!(
        invocation: invocation,
        session: replay_session,
        operation_id: "operation-123",
        method_name: "conversation.settings.update",
        payload: { "tone" => "concise" },
        status: "applied",
        response_snapshot: { "ok" => false },
      )

    assert_equal false, first.fetch(:replayed)
    assert_equal true, replay.fetch(:replayed)
    assert_equal first.fetch(:receipt).id, replay.fetch(:receipt).id
    assert_equal({ "ok" => true }, replay.fetch(:receipt).response_snapshot)
  end

  test "lifecycle caller binds the open callback session to the invocation before the remote call starts" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_runtime!(endpoint_url: server.rpc_url)
    observed_session_invocation_ids = []

    AgentRPC::LifecycleCaller.call!(
      deployment: runtime.fetch(:deployment),
      conversation: runtime.fetch(:conversation),
      scope_type: "run_draft",
      scope_id: "draft-123",
      method_name: "before_agent_step",
      invocation_id: "invoke-123",
      request_payload: { "user_input" => "Hello" },
      allowed_callback_methods: %w[conversation.settings.update],
      rpc_client_factory: lambda do |deployment:, session:, invocation:, **_kwargs|
        Object.new.tap do |client|
          client.define_singleton_method(:call) do |_method_name, _params|
            observed_session_invocation_ids << session.reload.agent_rpc_invocation_id
            { "planning" => { "step_plan" => { "fixture" => true, "invocation_id" => invocation.id } } }
          end
        end
      end,
    )

    invocation =
      AgentRPCInvocation.find_by!(
        agent_id: runtime.fetch(:agent).id,
        invocation_id: "invoke-123",
        scope_id: "draft-123",
      )

    assert_equal [invocation.id], observed_session_invocation_ids
    assert_equal "closed", invocation.last_session.reload.status
  ensure
    server&.shutdown
  end

  private

    def create_runtime!(endpoint_url: "http://127.0.0.1:4319/rpc", deployment_fingerprint: "fixture-deployment-v1")
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
          deployment_fingerprint: deployment_fingerprint,
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
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      conversation =
        create_conversation!(
          agent: agent,
          agent_program: program,
          default_execution_target: target,
        )

      { agent: agent, conversation: conversation, program: program, deployment: deployment, recognized_deployment: recognized_deployment, target: target }
    end

    def replacement_deployment!(program:, deployment_fingerprint:, activated_at: Time.current.change(usec: 0))
      create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: "contract:v1",
        deployment_fingerprint: deployment_fingerprint,
        status: "inactive",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: activated_at,
      )
    end

    def create_session!(agent:, recognized_deployment:, deployment:, conversation:, invocation:)
      AgentRPCSession.create!(
        agent: agent,
        recognized_deployment: recognized_deployment,
        recognized_deployment_key: recognized_deployment.recognized_deployment_key,
        agent_rpc_invocation: invocation,
        conversation: conversation,
        scope_type: invocation.scope_type,
        scope_id: invocation.scope_id,
        deployment_fingerprint: invocation.binding_fingerprint,
        deployment_activated_at: invocation.deployment_activated_at,
        session_token_digest: Digest::SHA256.hexdigest("arpc_#{SecureRandom.hex(24)}"),
        allowed_methods: %w[conversation.settings.update],
        expires_at: 5.minutes.from_now.change(usec: 0),
        status: "open",
      )
    end
end
