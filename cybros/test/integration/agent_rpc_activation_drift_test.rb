require "test_helper"

class AgentRPCActivationDriftTest < ActiveSupport::TestCase
  test "activation cutover rejects replay against a replacement deployment without leaking a new callback session" do
    primary_server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture-v1").start
    replacement_prepare_calls = []
    replacement_server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture-v2",
        identity_overrides: { "deployment_fingerprint" => "fixture-deployment-v2" },
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            replacement_prepare_calls << params.fetch("invocation_id")
            base_result
          end,
        },
      ).start
    runtime =
      create_runtime!(
        endpoint_url: primary_server.rpc_url,
        deployment_bearer_secret_ref: "secret://fixture-v1",
        deployment_fingerprint: "fixture-deployment-v1",
      )

    first_error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::LifecycleCaller.call!(
          deployment: runtime.fetch(:deployment),
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: "draft-123",
          method_name: "turn.prepare",
          invocation_id: "invoke-123",
          request_payload: { "user_input" => "Hello" },
          allowed_callback_methods: %w[conversation.settings.get],
          rpc_client_factory: lambda do |**_kwargs|
            Object.new.tap do |client|
              client.define_singleton_method(:call) do |_method_name, _params|
                raise AgentRPC::LostReplyError, "lost reply after dispatch"
              end
            end
          end,
        )
      end

    assert_equal "cybros.agent_rpc.reply_unknown", first_error.code

    invocation = AgentRPCInvocation.find_by!(invocation_id: "invoke-123", scope_id: "draft-123")
    runtime.fetch(:deployment).update!(status: "inactive", deactivated_at: Time.current.change(usec: 0))
    replacement =
      replacement_deployment!(
        program: runtime.fetch(:program),
        endpoint_url: replacement_server.rpc_url,
        deployment_bearer_secret_ref: "secret://fixture-v2",
        deployment_fingerprint: "fixture-deployment-v2",
      )

    drift_error =
      assert_raises(AgentCore::ValidationError) do
        AgentRPC::LifecycleCaller.call!(
          deployment: replacement,
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: "draft-123",
          method_name: "turn.prepare",
          invocation_id: "invoke-123",
          request_payload: { "user_input" => "Hello" },
          allowed_callback_methods: %w[conversation.settings.get],
        )
      end

    assert_equal "cybros.agent_rpc.invocation_binding_mismatch", drift_error.code
    assert_equal [], replacement_prepare_calls
    assert_equal invocation.id, AgentRPCInvocation.find_by!(invocation_id: "invoke-123", scope_id: "draft-123").id
    assert_equal "reply_unknown", invocation.reload.status
    assert_equal 0, AgentRPCSession.where(agent_deployment: replacement, status: "open").count
  ensure
    primary_server&.shutdown
    replacement_server&.shutdown
  end

  private

    def create_runtime!(endpoint_url:, deployment_bearer_secret_ref:, deployment_fingerprint:)
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
          deployment_bearer_secret_ref: deployment_bearer_secret_ref,
          contract_fingerprint: "contract:v1",
          deployment_fingerprint: deployment_fingerprint,
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

      { conversation: conversation, program: program, deployment: deployment }
    end

    def replacement_deployment!(program:, endpoint_url:, deployment_bearer_secret_ref:, deployment_fingerprint:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: deployment_bearer_secret_ref,
        contract_fingerprint: "contract:v1",
        deployment_fingerprint: deployment_fingerprint,
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
    end
end
