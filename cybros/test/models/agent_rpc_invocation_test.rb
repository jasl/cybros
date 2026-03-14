require "test_helper"

class AgentRPCInvocationTest < ActiveSupport::TestCase
  FIXED_DEPLOYMENT_ACTIVATED_AT = Time.utc(2026, 3, 9, 12, 0, 0)

  test "defaults deployment_activated_at to the agent deployment activation time" do
    activated_at = FIXED_DEPLOYMENT_ACTIVATED_AT
    deployment =
      create_runtime_binding_record!(
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
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: activated_at,
      )

    invocation = build_invocation(deployment: deployment)

    assert_equal activated_at, invocation.deployment_activated_at
  end

  test "deduplicates replay-safe invocations within the same agent deployment" do
    invocation = build_invocation
    invocation.save!

    duplicate =
      build_invocation(
        deployment: invocation.recognized_deployment.agent,
        conversation: invocation.conversation,
        result_snapshot: { "ok" => false },
      )

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:invocation_id], "has already been taken"
  end

  test "treats copied deployment rows with the same recognized runtime identity as the same binding" do
    invocation = build_invocation
    invocation.save!
    copied_binding_deployment =
      build_deployment!(
        program: invocation.recognized_deployment.agent,
        deployment_fingerprint: invocation.recognized_deployment.deployment_fingerprint,
        status: "inactive",
      )

    duplicate =
      build_invocation(
        deployment: copied_binding_deployment,
        conversation: invocation.conversation,
        binding_fingerprint: invocation.binding_fingerprint,
        deployment_activated_at: invocation.deployment_activated_at,
      )

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
    conversation = attributes[:conversation] || create_conversation!
    deployment = attributes[:deployment] || build_deployment!(program: attributes[:agent_program] || create_program!)
    agent = attributes[:agent] || create_agent_runtime!(program: deployment, execution_target: build_default_execution_profile!, deployment: deployment)
    recognized_deployment = attributes[:recognized_deployment] || recognize_agent_runtime!(agent: agent, deployment: deployment)

    AgentRPCInvocation.new(
      {
        agent: agent,
        recognized_deployment: recognized_deployment,
        recognized_deployment_key: recognized_deployment.recognized_deployment_key,
        conversation: conversation,
        scope_type: "run_draft",
        scope_id: "scope-123",
        method: "before_agent_step",
        invocation_id: "invoke-123",
        binding_fingerprint: "binding:v1",
        deployment_activated_at: deployment.activated_at || FIXED_DEPLOYMENT_ACTIVATED_AT,
        request_payload_hash: SecureRandom.hex(16),
        status: "succeeded",
        result_snapshot: { "ok" => true },
        error_snapshot: { "message" => "none" },
      }.merge(attributes.except(:agent_program, :deployment)),
    )
  end

  def create_program!
    create_agent_record!(
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
    create_runtime_binding_record!(
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
      supported_methods: Agents::Protocol::REQUIRED_METHODS,
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
      activated_at: activated_at || (status == "active" ? FIXED_DEPLOYMENT_ACTIVATED_AT : nil),
    )
  end
end
