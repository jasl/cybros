require "test_helper"

module AgentRPC
  class LifecycleCallerTest < ActiveSupport::TestCase
    test "rejects reply unknown replay once the deployment binding is no longer active and healthy" do
      runtime = create_runtime!
      invocation =
        InvocationStore.start_or_replay!(
          deployment: runtime.fetch(:deployment),
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: "draft-123",
          method_name: "turn.prepare",
          invocation_id: "invoke-123",
          request_payload: { "user_input" => "Hello" },
        ).fetch(:invocation)

      InvocationStore.mark_reply_unknown!(
        invocation: invocation,
        error_snapshot: { "message" => "lost reply", "kind" => "lost_reply" },
      )
      runtime.fetch(:deployment).update!(
        status: "inactive",
        health_status: "unhealthy",
        deactivated_at: Time.current.change(usec: 0),
      )

      remote_call_count = 0
      error =
        assert_raises(AgentCore::ValidationError) do
          LifecycleCaller.call!(
            deployment: runtime.fetch(:deployment).reload,
            conversation: runtime.fetch(:conversation),
            scope_type: "run_draft",
            scope_id: "draft-123",
            method_name: "turn.prepare",
            invocation_id: "invoke-123",
            request_payload: { "user_input" => "Hello" },
            allowed_callback_methods: %w[conversation.settings.get],
            rpc_client_factory: lambda do |**_kwargs|
              remote_call_count += 1
              raise "remote client should not be constructed"
            end,
          )
        end

      assert_equal "cybros.agent_rpc.deployment_activation_drift", error.code
      assert_equal 0, remote_call_count
      assert_equal "reply_unknown", invocation.reload.status
      assert_equal 0, AgentRPCSession.where(agent_rpc_invocation: invocation).count
    end

    private

      def create_runtime!
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
            endpoint_url: "http://127.0.0.1:4319/rpc",
            deployment_bearer_secret_ref: "secret://fixture",
            contract_fingerprint: "contract:v1",
            deployment_fingerprint: "fixture-deployment-v1",
            status: "active",
            health_status: "healthy",
            protocol_version: "agent_rpc.v1",
            agent_sdk_version: "fixture-ruby-sdk/1.0",
            supported_methods: AgentDeployments::REQUIRED_METHODS,
            transport_config: {},
            manifest_snapshot: {},
            schema_snapshot: {},
            capability_snapshot: {},
            inspection_details: {},
            activated_at: Time.current.change(usec: 0),
          )

        { conversation: conversation, program: program, deployment: deployment }
      end
  end
end
