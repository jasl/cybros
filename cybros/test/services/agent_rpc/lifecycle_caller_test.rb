require "test_helper"

module AgentRPC
  class LifecycleCallerTest < ActiveSupport::TestCase
    test "marks invocation failed when result validation fails after the remote reply" do
      runtime = create_runtime!
      server =
        Cybros::ProgrammableAgentFixture::Server.new(
          required_bearer: "secret://fixture",
          rpc_overrides: {
            "after_task_notice" => lambda do |_params, _base_result, _identity|
              { "actions" => [{ "type" => "not_a_real_action" }] }
            end,
          },
        ).start
      runtime.fetch(:deployment).update!(
        endpoint_url: server.rpc_url,
        deployment_bearer_secret_ref: "secret://fixture",
        supported_methods: Agents::Protocol::REQUIRED_METHODS + %w[after_task_notice],
      )
      sync_agent_runtime_from_binding!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

      error =
        assert_raises(AgentCore::ValidationError) do
          LifecycleCaller.call!(
            deployment: runtime.fetch(:deployment).reload,
            conversation: runtime.fetch(:conversation),
            scope_type: "conversation_run",
            scope_id: "run-123",
            method_name: "after_task_notice",
            invocation_id: "invoke-invalid-envelope",
            request_payload: { "task_notice" => { "notice" => { "kind" => "provider_error" } } },
            allowed_callback_methods: [],
            result_validator: lambda do |result|
              Cybros::ProgrammableAgent::HookEnvelope.parse!(
                hook_name: "after_task_notice",
                request_payload: {},
                payload: result,
              )
            end,
          )
        end

      invocation = AgentRPCInvocation.find_by!(invocation_id: "invoke-invalid-envelope")

      assert_equal "cybros.programmable_agent.hook_contract.invalid_action_type", error.code
      assert_equal "failed", invocation.reload.status
      assert_equal({ "actions" => [{ "type" => "not_a_real_action" }] }, invocation.result_snapshot)
      assert_equal "cybros.programmable_agent.hook_contract.invalid_action_type", invocation.error_snapshot.fetch("code")
    ensure
      server&.shutdown
    end

    test "rejects reply unknown replay once the deployment binding is no longer active and healthy" do
      runtime = create_runtime!
      invocation =
        InvocationStore.start_or_replay!(
          agent: runtime.fetch(:agent),
          recognized_deployment: runtime.fetch(:recognized_deployment),
          deployment: runtime.fetch(:deployment),
          conversation: runtime.fetch(:conversation),
          scope_type: "run_draft",
          scope_id: "draft-123",
          method_name: "before_agent_step",
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
      sync_agent_runtime_from_binding!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

      remote_call_count = 0
      error =
        assert_raises(AgentCore::ValidationError) do
          LifecycleCaller.call!(
            deployment: runtime.fetch(:deployment).reload,
            conversation: runtime.fetch(:conversation),
            scope_type: "run_draft",
            scope_id: "draft-123",
            method_name: "before_agent_step",
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
        program =
          create_agent_record!(
            name: "Fixture Program",
            config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
            published_contract_fingerprint: "contract:v1",
            manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Program" },
            global_config: {},
            global_config_schema: { "type" => "object" },
            conversation_config_schema: { "type" => "object" },
            config_schema_fingerprint: "config:v1",
          )
        target = build_default_execution_profile!
        agent = materialize_agent_runtime!(program: program, execution_target: target)
        deployment =
          create_runtime_binding_record!(
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
            supported_methods: Agents::Protocol::REQUIRED_METHODS,
            transport_config: {},
            manifest_snapshot: {},
            schema_snapshot: {},
            capability_snapshot: {},
            inspection_details: {},
            activated_at: Time.current.change(usec: 0),
          )
        sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)
        recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
        conversation =
          create_conversation!(
            agent: agent,
            agent_program: program,
            default_execution_target: target,
          )

        { agent: agent, conversation: conversation, deployment: deployment, program: program, recognized_deployment: recognized_deployment }
      end
  end
end
