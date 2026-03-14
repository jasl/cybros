require "test_helper"

class AgentRPCOperationReceiptTest < ActiveSupport::TestCase
  test "deduplicates operation ids per invocation" do
    invocation = create_invocation!

    AgentRPCOperationReceipt.create!(
      agent_rpc_invocation: invocation,
      operation_id: "operation-123",
      method: "lane.kv.set",
      payload_hash: "sha256:payload",
      status: "applied",
      response_snapshot: { "ok" => true },
    )

    duplicate =
      AgentRPCOperationReceipt.new(
        agent_rpc_invocation: invocation,
        operation_id: "operation-123",
        method: "lane.kv.set",
        payload_hash: "sha256:payload",
        status: "applied",
        response_snapshot: { "ok" => true },
      )

    refute duplicate.valid?
    assert_includes duplicate.errors[:operation_id], "has already been taken"
  end

  private

    def create_invocation!
      program =
        create_agent_record!(
          name: "Fixture Program",
          manifest_snapshot: { "name" => "Fixture Program" },
          global_config_schema: { "type" => "object", "properties" => {} },
          conversation_config_schema: { "type" => "object", "properties" => {} },
        )
      target = build_default_execution_profile!
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      deployment =
        create_runtime_binding_record!(
          agent_program: program,
          transport_kind: "websocket",
          endpoint_url: "ws://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS,
          manifest_snapshot: { "name" => "Fixture Program" },
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

      AgentRPCInvocation.create!(
        agent: agent,
        recognized_deployment: recognized_deployment,
        recognized_deployment_key: recognized_deployment.recognized_deployment_key,
        conversation: conversation,
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        method: "before_agent_step",
        invocation_id: "invoke-123",
        binding_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: Time.current,
        request_payload_hash: "sha256:payload-1",
        status: "succeeded",
      )
    end
end
