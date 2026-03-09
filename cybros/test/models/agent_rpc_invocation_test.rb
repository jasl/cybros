require "test_helper"

class AgentRpcInvocationTest < ActiveSupport::TestCase
  test "deduplicates replay-safe invocations by binding and invocation id" do
    build_invocation.save!

    duplicate = build_invocation(result_snapshot: { "ok" => false })

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:invocation_id], "has already been taken"
  end

  test "persists result and error snapshots" do
    invocation = build_invocation

    assert_predicate invocation, :valid?
    invocation.save!

    assert_equal({ "ok" => true }, invocation.result_snapshot)
    assert_equal({ "message" => "none" }, invocation.error_snapshot)
  end

  private

  def build_invocation(attributes = {})
    conversation = create_conversation!
    program = AgentProgram.create!(
      name: "Fixture Program",
      config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:v1",
      manifest_snapshot: {},
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:v1",
    )
    deployment = AgentDeployment.create!(
      agent_program: program,
      transport_kind: "websocket",
      endpoint_url: "http://127.0.0.1:4319/rpc",
      deployment_bearer_secret_ref: "secret://fixture",
      contract_fingerprint: "contract:v1",
      deployment_fingerprint: "deployment:v1",
      status: "active",
      health_status: "healthy",
      protocol_version: "agent_rpc.v1",
      agent_sdk_version: "fixture-ruby-sdk/1.0",
      supported_methods: %w[initialize turn.prepare turn.compose],
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
    )

    AgentRpcInvocation.new(
      {
        agent_deployment: deployment,
        conversation: conversation,
        scope_type: "run_draft",
        scope_id: "scope-123",
        method: "turn.prepare",
        invocation_id: "invoke-123",
        binding_fingerprint: "binding:v1",
        deployment_activated_at: Time.current.change(usec: 0),
        request_payload_hash: SecureRandom.hex(16),
        status: "succeeded",
        result_snapshot: { "ok" => true },
        error_snapshot: { "message" => "none" },
      }.merge(attributes),
    )
  end
end
