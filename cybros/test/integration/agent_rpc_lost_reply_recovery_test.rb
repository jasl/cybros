require "test_helper"

class AgentRpcLostReplyRecoveryTest < ActiveSupport::TestCase
  test "lost reply recovery replays the same invocation on the same binding and reuses the logical invocation record" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_runtime!(endpoint_url: server.rpc_url)
    responses = [AgentRpc::LostReplyError.new("lost reply after dispatch"), { "prepared_plan" => { "fixture" => true } }]
    call_count = 0

    first_error =
      assert_raises(AgentCore::ValidationError) do
        AgentRpc::LifecycleCaller.call!(
          deployment: runtime.fetch(:deployment),
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: "draft-123",
          method_name: "turn.prepare",
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

    invocation = AgentRpcInvocation.find_by!(invocation_id: "invoke-123", scope_id: "draft-123")
    assert_equal "cybros.agent_rpc.reply_unknown", first_error.code
    assert_equal "reply_unknown", invocation.status

    recovered =
      AgentRpc::LifecycleCaller.call!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "run_draft",
        scope_id: "draft-123",
          method_name: "turn.prepare",
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

    assert_equal true, recovered.fetch("prepared_plan", {}).fetch("fixture")
    assert_equal 2, call_count
    assert_equal invocation.id, AgentRpcInvocation.find_by!(invocation_id: "invoke-123", scope_id: "draft-123").id
    assert_equal "succeeded", invocation.reload.status
    assert_equal 2, AgentRpcSession.where(agent_rpc_invocation: invocation).count
  ensure
    server&.shutdown
  end

  private

    def create_runtime!(endpoint_url:)
      conversation = create_conversation!
      program =
        AgentProgram.create!(
          name: "Fixture Program",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      deployment =
        AgentDeployment.create!(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: "contract:v1",
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: AgentDeployments::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )

      { conversation: conversation, deployment: deployment }
    end
end
