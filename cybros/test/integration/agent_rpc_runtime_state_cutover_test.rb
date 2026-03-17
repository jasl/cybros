require "test_helper"

class AgentRPCRuntimeStateCutoverTest < ActiveSupport::TestCase
  test "agent rpc sessions and invocations snapshot agent and recognized deployment bindings" do
    assert_includes AgentRPCSession.attribute_names, "agent_id"
    assert_includes AgentRPCSession.attribute_names, "recognized_deployment_id"
    assert_includes AgentRPCSession.attribute_names, "recognized_deployment_key"
    refute_includes AgentRPCSession.attribute_names, "agent_program_id"
    refute_includes AgentRPCSession.attribute_names, "agent_deployment_id"

    assert_includes AgentRPCInvocation.attribute_names, "agent_id"
    assert_includes AgentRPCInvocation.attribute_names, "recognized_deployment_id"
    assert_includes AgentRPCInvocation.attribute_names, "recognized_deployment_key"
    refute_includes AgentRPCInvocation.attribute_names, "agent_deployment_id"

    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_programmable_runtime!(server:)

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

    assert_equal draft.agent_id, invocation.agent_id
    assert_equal draft.recognized_deployment_id, invocation.recognized_deployment_id
    assert_equal draft.recognized_deployment_key, invocation.recognized_deployment_key
    assert_equal draft.agent_id, session.agent_id
    assert_equal draft.recognized_deployment_id, session.recognized_deployment_id
    assert_equal draft.recognized_deployment_key, session.recognized_deployment_key
  ensure
    server&.shutdown
  end

  test "invocation replay reuses the same row for the same recognized deployment binding" do
    runtime = create_programmable_runtime!

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
    second =
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

    assert_equal first.fetch(:invocation).id, second.fetch(:invocation).id
    assert_equal true, second.fetch(:replayed)
  end

  test "invocation replay keys split when recognized deployment changes" do
    runtime = create_programmable_runtime!
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
    changed_recognized_deployment =
      RecognizedDeployment.recognize!(
        agent: runtime.fetch(:agent),
        deployment: runtime.fetch(:deployment),
        initialize_result: {
          "identity" => {
            "agent_key" => runtime.fetch(:program).manifest_snapshot.fetch("agent_key"),
            "deployment_fingerprint" => runtime.fetch(:deployment).deployment_fingerprint,
            "protocol_version" => runtime.fetch(:deployment).protocol_version,
            "agent_sdk_version" => runtime.fetch(:deployment).agent_sdk_version,
            "supported_methods" => runtime.fetch(:deployment).supported_methods + ["attachments.import"],
          },
        },
        capability_snapshot: runtime.fetch(:deployment).capability_snapshot.merge("agent_capabilities_version" => "2026-03-14"),
      )

    second =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: runtime.fetch(:agent),
        recognized_deployment: changed_recognized_deployment,
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
        method_name: "before_agent_step",
        invocation_id: "invoke-123",
        request_payload: { "user_input" => "Hello" },
      )

    assert_not_equal first.fetch(:invocation).id, second.fetch(:invocation).id
    assert_equal false, second.fetch(:replayed)
  end

  private

    def create_programmable_runtime!(server: nil)
      user = create_user!
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
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server&.rpc_url || "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
          manifest_snapshot: program.manifest_snapshot,
          schema_snapshot: {},
          capability_snapshot: { "agent_capabilities_version" => "2026-03-13" },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      agent = deployment
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)
      ensure_llm_provider!(
        provider_key: "openai",
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
      )
      conversation =
        create_conversation!(
          user: user,
          title: "Chat",
          agent: agent,
        )
      conversation.update!(
        permission_mode: "default",
        agent_config_schema_fingerprint: agent.config_schema_fingerprint,
      )

      {
        agent: agent,
        conversation: conversation,
        deployment: deployment,
        program: program,
        recognized_deployment: recognized_deployment,
      }
    end
end
