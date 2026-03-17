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
    other_invocation = create_invocation!

    session =
      build_session(
        agent: invocation.agent,
        recognized_deployment: other_invocation.recognized_deployment,
        recognized_deployment_key: other_invocation.recognized_deployment_key,
        agent_rpc_invocation: invocation,
        conversation: invocation.conversation,
        scope_id: invocation.scope_id,
      )

    refute_predicate session, :valid?
    assert_includes session.errors[:recognized_deployment], "must belong to the selected agent"
    assert_includes session.errors[:agent_rpc_invocation], "must match the recognized deployment binding"
  end

  private

  def build_session(attributes = {})
    invocation = create_invocation!

    AgentRPCSession.new(
      {
        agent: invocation.agent,
        recognized_deployment: invocation.recognized_deployment,
        recognized_deployment_key: invocation.recognized_deployment_key,
        agent_rpc_invocation: invocation,
        conversation: invocation.conversation,
        scope_type: "run_draft",
        scope_id: invocation.scope_id,
        deployment_fingerprint: invocation.binding_fingerprint,
        deployment_activated_at: invocation.deployment_activated_at,
        session_token_digest: SecureRandom.hex(16),
        allowed_methods: %w[conversation.settings.get tool_surface.manifest],
        expires_at: 15.minutes.from_now.change(usec: 0),
        status: "open",
      }.merge(attributes),
    )
  end

  def create_invocation!
    program = create_agent_record!(
      name: "Fixture Program",
      config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:v1",
      manifest_snapshot: {},
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:v1",
    )
    deployment = create_runtime_binding_record!(
      agent: program,
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
