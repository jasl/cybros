require "test_helper"

class AgentRPCLostReplyRecoveryTest < ActiveSupport::TestCase
  test "lost reply recovery replays the same invocation on the same binding and reuses the logical invocation record" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_runtime!(endpoint_url: server.rpc_url)
    responses = [AgentRPC::LostReplyError.new("lost reply after dispatch"), { "planning" => { "step_plan" => { "fixture" => true } } }]
    call_count = 0

    first_error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::LifecycleCaller.call!(
          deployment: runtime.fetch(:deployment),
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: "draft-123",
          method_name: "before_agent_step",
          invocation_id: "invoke-123",
          request_payload: { "user_input" => "Hello" },
          allowed_callback_methods: %w[conversation.settings.get],
          rpc_client_factory: lambda do |deployment:, **_kwargs|
            Object.new.tap do |client|
              client.define_singleton_method(:call) do |_method_name, _params|
                call_count += 1
                outcome = responses.shift
                raise outcome if outcome.is_a?(Exception)

                outcome
              end
            end
          end,
        )
      end

    invocation = AgentRPCInvocation.find_by!(invocation_id: "invoke-123", scope_id: "draft-123")
    assert_equal "cybros.agent_rpc.reply_unknown", first_error.code
    assert_equal "reply_unknown", invocation.status

    recovered =
      AgentRPC::LifecycleCaller.call!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
          method_name: "before_agent_step",
          invocation_id: "invoke-123",
          request_payload: { "user_input" => "Hello" },
          allowed_callback_methods: %w[conversation.settings.get],
          rpc_client_factory: lambda do |deployment:, **_kwargs|
            Object.new.tap do |client|
              client.define_singleton_method(:call) do |_method_name, _params|
                call_count += 1
                responses.shift
            end
          end
        end,
      )

    assert_equal true, recovered.dig("planning", "step_plan", "fixture")
    assert_equal 2, call_count
    assert_equal invocation.id, AgentRPCInvocation.find_by!(invocation_id: "invoke-123", scope_id: "draft-123").id
    assert_equal "succeeded", invocation.reload.status
    assert_equal 2, AgentRPCSession.where(agent_rpc_invocation: invocation).count
  ensure
    server&.shutdown
  end

  private

    def create_runtime!(endpoint_url:)
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
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: "contract:v1",
          deployment_fingerprint: "fixture-deployment-v1",
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
      target = build_default_execution_profile!
      agent = materialize_agent_runtime!(agent: program, execution_profile: target)
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      conversation =
        create_conversation!(
          agent: agent,
        )

      { agent: agent, recognized_deployment: recognized_deployment, conversation: conversation, deployment: deployment }
    end
end
