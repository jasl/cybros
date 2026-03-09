require "test_helper"

class AgentRpcOperationReceiptTest < ActiveSupport::TestCase
  test "deduplicates operation ids per invocation" do
    invocation = create_invocation!

    AgentRpcOperationReceipt.create!(
      agent_rpc_invocation: invocation,
      operation_id: "operation-123",
      method: "conversation.kv.set",
      payload_hash: "sha256:payload",
      status: "applied",
      response_snapshot: { "ok" => true },
    )

    duplicate =
      AgentRpcOperationReceipt.new(
        agent_rpc_invocation: invocation,
        operation_id: "operation-123",
        method: "conversation.kv.set",
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
        AgentProgram.create!(
          name: "Fixture Program",
          manifest_snapshot: { "name" => "Fixture Program" },
          global_config_schema: { "type" => "object", "properties" => {} },
          conversation_config_schema: { "type" => "object", "properties" => {} },
        )
      deployment =
        AgentDeployment.create!(
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
          supported_methods: %w[initialize turn.prepare turn.compose],
          manifest_snapshot: { "name" => "Fixture Program" },
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
        )

      AgentRpcInvocation.create!(
        agent_deployment: deployment,
        conversation: create_conversation!,
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        method: "turn.prepare",
        invocation_id: "invoke-123",
        binding_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: Time.current,
        request_payload_hash: "sha256:payload-1",
        status: "succeeded",
      )
    end
end
