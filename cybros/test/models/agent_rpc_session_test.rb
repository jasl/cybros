require "test_helper"

class AgentRPCSessionTest < ActiveSupport::TestCase
  test "requires scoped session identity" do
    session =
      build_session(
        session_token_digest: nil,
        scope_type: nil,
        scope_id: nil,
        allowed_methods: [],
        status: nil,
      )

    refute_predicate session, :valid?
    assert_includes session.errors[:session_token_digest], "can't be blank"
    assert_includes session.errors[:scope_type], "can't be blank"
    assert_includes session.errors[:scope_id], "can't be blank"
    assert_includes session.errors[:status], "can't be blank"
  end

  test "allows sessions with no callback methods" do
    session = build_session(allowed_methods: [])

    assert_predicate session, :valid?
    assert_equal [], session.allowed_methods
  end

  test "requires invocation and deployment bindings to stay aligned" do
    invocation = create_invocation!
    other_program =
      AgentProgram.create!(
        name: "Other Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v2",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v2",
      )

    session =
      build_session(
        agent_program: other_program,
        agent_deployment: invocation.agent_deployment,
        agent_rpc_invocation: invocation,
        conversation: invocation.conversation,
        scope_id: invocation.scope_id,
      )

    refute_predicate session, :valid?
    assert_includes session.errors[:agent_deployment], "must belong to the selected agent program"
    assert_includes session.errors[:agent_rpc_invocation], "must match the deployment binding"
  end

  private

  def build_session(attributes = {})
    invocation = create_invocation!

    AgentRPCSession.new(
      {
        agent_deployment: invocation.agent_deployment,
        agent_program: invocation.agent_deployment.agent_program,
        agent_rpc_invocation: invocation,
        conversation: invocation.conversation,
        scope_type: "run_draft",
        scope_id: invocation.scope_id,
        deployment_fingerprint: invocation.binding_fingerprint,
        deployment_activated_at: invocation.deployment_activated_at,
        session_token_digest: SecureRandom.hex(16),
        allowed_methods: %w[conversation.settings.get execution_target.list],
        expires_at: 15.minutes.from_now.change(usec: 0),
        status: "open",
      }.merge(attributes),
    )
  end

  def create_invocation!
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

    AgentRPCInvocation.create!(
      agent_deployment: deployment,
      conversation: conversation,
      scope_type: "run_draft",
      scope_id: SecureRandom.uuid,
      method: "turn.prepare",
      invocation_id: "invoke-#{SecureRandom.hex(6)}",
      binding_fingerprint: "deployment:v1",
      deployment_activated_at: Time.current.change(usec: 0),
      request_payload_hash: SecureRandom.hex(16),
      status: "succeeded",
      result_snapshot: { "ok" => true },
      error_snapshot: {},
    )
  end
end
