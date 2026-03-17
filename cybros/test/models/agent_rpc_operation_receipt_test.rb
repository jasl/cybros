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

  test "record_or_replay reuses the first conversation memory append snapshot" do
    invocation = create_invocation!
    session = create_session!(invocation: invocation)

    first =
      AgentRPC::OperationReceiptStore.record_or_replay!(
        invocation: invocation,
        session: session,
        operation_id: "operation-memory-append",
        method_name: "conversation.memory.append",
        payload: { "text" => "\nRemember beta" },
        status: "applied",
        response_snapshot: {
          "document" => {
            "kind" => "conversation_memory",
            "body" => "Remember alpha\nRemember beta",
          },
        },
      )
    replay =
      AgentRPC::OperationReceiptStore.record_or_replay!(
        invocation: invocation,
        session: session,
        operation_id: "operation-memory-append",
        method_name: "conversation.memory.append",
        payload: { "text" => "\nRemember beta" },
        status: "applied",
        response_snapshot: {
          "document" => {
            "kind" => "conversation_memory",
            "body" => "should not replace the stored snapshot",
          },
        },
      )

    assert_equal false, first.fetch(:replayed)
    assert_equal true, replay.fetch(:replayed)
    assert_equal first.fetch(:receipt).id, replay.fetch(:receipt).id
    assert_equal(
      "Remember alpha\nRemember beta",
      replay.fetch(:receipt).response_snapshot.dig("document", "body"),
    )
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
      deployment =
        create_runtime_binding_record!(
          agent: program,
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
      agent = deployment
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      conversation = create_conversation!(agent: agent)

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

    def create_session!(invocation:)
      AgentRPCSession.create!(
        agent: invocation.agent,
        recognized_deployment: invocation.recognized_deployment,
        recognized_deployment_key: invocation.recognized_deployment_key,
        agent_rpc_invocation: invocation,
        conversation: invocation.conversation,
        scope_type: invocation.scope_type,
        scope_id: invocation.scope_id,
        deployment_fingerprint: invocation.binding_fingerprint,
        deployment_activated_at: invocation.deployment_activated_at,
        session_token_digest: Digest::SHA256.hexdigest("arpc_#{SecureRandom.hex(24)}"),
        allowed_methods: %w[conversation.memory.append],
        expires_at: 5.minutes.from_now.change(usec: 0),
        status: "open",
      )
    end
end
