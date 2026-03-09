require "test_helper"

class AgentRPCInvocationTest < ActiveSupport::TestCase
  FIXED_DEPLOYMENT_ACTIVATED_AT = Time.utc(2026, 3, 9, 12, 0, 0)

  test "defaults deployment_activated_at to the agent deployment activation time" do
    activated_at = FIXED_DEPLOYMENT_ACTIVATED_AT
    deployment =
      AgentDeployment.create!(
        agent_program: create_program!,
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
        activated_at: activated_at,
      )

    invocation = build_invocation(agent_deployment: deployment)

    assert_equal activated_at, invocation.deployment_activated_at
  end

  test "deduplicates replay-safe invocations within the same agent deployment" do
    invocation = build_invocation
    invocation.save!

    duplicate =
      build_invocation(
        agent_deployment: invocation.agent_deployment,
        conversation: invocation.conversation,
        result_snapshot: { "ok" => false },
      )

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:invocation_id], "has already been taken"
  end

  test "allows the same invocation id for a copied binding on a different agent deployment row" do
    invocation = build_invocation
    invocation.save!
    copied_binding_deployment =
      build_deployment!(
        program: invocation.agent_deployment.agent_program,
        deployment_fingerprint: invocation.agent_deployment.deployment_fingerprint,
        status: "inactive",
      )

    duplicate =
      build_invocation(
        agent_deployment: copied_binding_deployment,
        conversation: invocation.conversation,
        binding_fingerprint: invocation.binding_fingerprint,
        deployment_activated_at: invocation.deployment_activated_at,
      )

    assert_predicate duplicate, :valid?
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
    conversation = attributes[:conversation] || create_conversation!
    deployment =
      attributes[:agent_deployment] ||
        build_deployment!(
          program: attributes[:agent_program] || create_program!,
        )

    AgentRPCInvocation.new(
      {
        agent_deployment: deployment,
        conversation: conversation,
        scope_type: "run_draft",
        scope_id: "scope-123",
        method: "turn.prepare",
        invocation_id: "invoke-123",
        binding_fingerprint: "binding:v1",
        deployment_activated_at: deployment.activated_at || FIXED_DEPLOYMENT_ACTIVATED_AT,
        request_payload_hash: SecureRandom.hex(16),
        status: "succeeded",
        result_snapshot: { "ok" => true },
        error_snapshot: { "message" => "none" },
      }.merge(attributes.except(:agent_program)),
    )
  end

  def create_program!
    AgentProgram.create!(
      name: "Fixture Program",
      config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:v1",
      manifest_snapshot: {},
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:v1",
    )
  end

  def build_deployment!(program:, deployment_fingerprint: "deployment:v1", status: "active", activated_at: nil)
    AgentDeployment.create!(
      agent_program: program,
      transport_kind: "websocket",
      endpoint_url: "http://127.0.0.1:4319/rpc",
      deployment_bearer_secret_ref: "secret://fixture",
      contract_fingerprint: "contract:v1",
      deployment_fingerprint: deployment_fingerprint,
      status: status,
      health_status: "healthy",
      protocol_version: "agent_rpc.v1",
      agent_sdk_version: "fixture-ruby-sdk/1.0",
      supported_methods: %w[initialize turn.prepare turn.compose],
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
      activated_at: activated_at || (status == "active" ? FIXED_DEPLOYMENT_ACTIVATED_AT : nil),
    )
  end
end
