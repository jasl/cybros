require "test_helper"

class AgentRpcInvocationReplayTest < ActiveSupport::TestCase
  test "replays the same invocation id only against the same pinned binding" do
    runtime = create_runtime!
    first =
      AgentRpc::InvocationStore.start_or_replay!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "turn.prepare",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    AgentRpc::InvocationStore.mark_succeeded!(
      invocation: first.fetch(:invocation),
      result_snapshot: { "prepared_plan" => { "fixture" => true } },
    )

    replay =
      AgentRpc::InvocationStore.start_or_replay!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "turn.prepare",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    assert_equal true, replay.fetch(:replayed)
    assert_equal first.fetch(:invocation).id, replay.fetch(:invocation).id

    replacement = replacement_deployment!(program: runtime.fetch(:program), deployment_fingerprint: "deployment:v2")
    error =
      assert_raises(AgentCore::ValidationError) do
        AgentRpc::InvocationStore.start_or_replay!(
          deployment: replacement,
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: "draft-123",
          method_name: "turn.prepare",
          invocation_id: "invoke-123",
          request_payload: { "user_input" => "Hello" },
        )
      end

    assert_equal "cybros.agent_rpc.invocation_binding_mismatch", error.code
  end

  test "deduplicates operation ids across replayed sessions for the same invocation" do
    runtime = create_runtime!
    invocation =
      AgentRpc::InvocationStore.start_or_replay!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "turn.prepare",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      ).fetch(:invocation)

    first_session = create_session!(deployment: runtime.fetch(:deployment), conversation: runtime.fetch(:conversation), invocation: invocation)
    replay_session = create_session!(deployment: runtime.fetch(:deployment), conversation: runtime.fetch(:conversation), invocation: invocation)

    first =
      AgentRpc::OperationReceiptStore.record_or_replay!(
        invocation: invocation,
        session: first_session,
        operation_id: "operation-123",
        method_name: "conversation.settings.update",
        payload: { "tone" => "concise" },
        status: "applied",
        response_snapshot: { "ok" => true },
      )
    replay =
      AgentRpc::OperationReceiptStore.record_or_replay!(
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

    AgentRpc::LifecycleCaller.call!(
      deployment: runtime.fetch(:deployment),
      conversation: runtime.fetch(:conversation),
      scope_type: "run_draft",
      scope_id: "draft-123",
      method_name: "turn.prepare",
      invocation_id: "invoke-123",
      request_payload: { "user_input" => "Hello" },
      allowed_callback_methods: %w[conversation.settings.update],
      rpc_client_factory: lambda do |deployment:, session:, invocation:, **_kwargs|
        Object.new.tap do |client|
          client.define_singleton_method(:call) do |_method_name, _params|
            observed_session_invocation_ids << session.reload.agent_rpc_invocation_id
            { "prepared_plan" => { "fixture" => true, "invocation_id" => invocation.id } }
          end
        end
      end,
    )

    invocation = AgentRpcInvocation.find_by!(invocation_id: "invoke-123", scope_id: "draft-123")

    assert_equal [invocation.id], observed_session_invocation_ids
    assert_equal "closed", invocation.last_session.reload.status
  ensure
    server&.shutdown
  end

  private

    def create_runtime!(endpoint_url: "http://127.0.0.1:4319/rpc", deployment_fingerprint: "fixture-deployment-v1")
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
      deployment =
        AgentDeployment.create!(
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
          supported_methods: AgentDeployments::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )

      { conversation: conversation, program: program, deployment: deployment }
    end

    def replacement_deployment!(program:, deployment_fingerprint:)
      AgentDeployment.create!(
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
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_session!(deployment:, conversation:, invocation:)
      AgentRpcSession.create!(
        agent_deployment: deployment,
        agent_program: deployment.agent_program,
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
