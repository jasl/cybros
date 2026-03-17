require "test_helper"

class RuntimeGovernance::ExecutionCapacityEnforcerTest < ActiveSupport::TestCase
  test "admit! acquires idempotently by durable execution request id for agent-scoped snapshots" do
    run = create_conversation_run!

    first = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run)
    second = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run)

    assert_equal "acquired", first.fetch(:decision)
    assert_equal first.fetch(:lease).id, second.fetch(:lease).id
    assert_equal "conversation_run:#{run.id}", first.fetch(:execution_request_id)
    assert_equal "agent", first.fetch(:capacity).fetch("scope_type")
    assert_equal run.agent_id, first.fetch(:capacity).fetch("scope_id")
  end

  test "admit! keeps agent-scoped lease identity even when imported capacity came from target overrides" do
    run_one = create_conversation_run!(max_concurrent_tasks: 2, max_queued_tasks: 3)
    run_two = create_conversation_run!(max_concurrent_tasks: 2, max_queued_tasks: 3)

    first = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run_one)
    second = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run_two)

    assert_equal "acquired", first.fetch(:decision)
    assert_equal "acquired", second.fetch(:decision)
    assert_equal "agent", first.fetch(:capacity).fetch("scope_type")
    assert_equal run_one.agent_id, first.fetch(:capacity).fetch("scope_id")
    assert_equal 2, first.fetch(:capacity).fetch("max_concurrent_tasks")
    assert_equal 3, first.fetch(:capacity).fetch("max_queued_tasks")
  end

  test "admit! requires an execution capacity snapshot" do
    run = create_conversation_run!
    ConversationRun.where(id: run.id).update_all(
      runtime_governors: {
        "provider_limiter" => provider_limiter_snapshot(
          provider_credential: run.provider_credential,
          selected_model_ref: run.selected_model_ref,
        ),
      },
    )
    run.reload

    error =
      assert_raises(AgentCore::ValidationError) do
        RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run)
      end

    assert_equal "cybros.runtime_governance.execution_capacity_snapshot_missing", error.code
  end

  private

    def create_conversation_run!(max_concurrent_tasks: 1, max_queued_tasks: 2, runtime_governors: nil)
      runtime = create_runtime!(max_concurrent_tasks: max_concurrent_tasks, max_queued_tasks: max_queued_tasks)
      conversation = create_conversation!(agent: runtime.fetch(:agent))
      runtime_governors ||= default_runtime_governors(runtime: runtime)

      ConversationRun.create!(
        build_conversation_run_attributes(
          conversation: conversation,
          dag_node_id: SecureRandom.uuid,
          agent: runtime.fetch(:agent),
          recognized_deployment: runtime.fetch(:recognized_deployment),
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          initiated_by_user: conversation.user,
          effective_permission_mode: "default",
          provider_credential: runtime.fetch(:credential),
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: runtime.fetch(:agent).config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: runtime_governors,
          snapshot: { "agent" => { "id" => runtime.fetch(:agent).id } },
        ),
      )
    end

    def default_runtime_governors(runtime:)
      runtime_governors_snapshot(
        provider_credential: runtime.fetch(:credential),
        selected_model_ref: "openai/gpt-5.4",
        agent: runtime.fetch(:agent),
      )
    end

    def create_runtime!(max_concurrent_tasks:, max_queued_tasks:)
      program = create_program!(max_concurrent_tasks: max_concurrent_tasks, max_queued_tasks: max_queued_tasks)
      deployment = create_deployment!(program)
      agent = create_agent_runtime!(agent: program, deployment: deployment)
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      credential =
        LLMProviderCredential.create!(
          provider_key: "openai-#{SecureRandom.hex(4)}",
          credential_type: "api_key",
          status: "active",
          api_key: "sk-test",
        )

      {
        agent: agent,
        credential: credential,
        deployment: deployment,
        program: program,
        recognized_deployment: recognized_deployment,
      }
    end

    def create_program!(max_concurrent_tasks: 4, max_queued_tasks: 16)
      create_agent_record!(
        name: "Fixture Program #{SecureRandom.hex(4)}",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
        max_concurrent_tasks: max_concurrent_tasks,
        max_queued_tasks: max_queued_tasks,
      )
    end

    def create_deployment!(program)
      create_runtime_binding_record!(
        agent: program,
        transport_kind: "websocket",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
        status: "active",
        health_status: "healthy",
        activated_at: Time.current.change(usec: 0),
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end
end
