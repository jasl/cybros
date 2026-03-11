require "test_helper"

class RuntimeGovernance::ExecutionCapacityEnforcerTest < ActiveSupport::TestCase
  test "admit! acquires idempotently by durable execution request id" do
    target = create_execution_target!(max_concurrent_tasks: 1, max_queued_tasks: 2)
    run = create_conversation_run!(execution_target: target)

    first = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run)
    second = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run)

    assert_equal "acquired", first.fetch(:decision)
    assert_equal first.fetch(:lease).id, second.fetch(:lease).id
    assert_equal "conversation_run:#{run.id}", first.fetch(:execution_request_id)
  end

  test "admit! honors execution target override snapshots" do
    target =
      create_execution_target!(
        max_concurrent_tasks: 1,
        max_queued_tasks: 2,
        max_concurrent_tasks_override: 2,
        max_queued_tasks_override: 3,
      )
    run_one = create_conversation_run!(execution_target: target)
    run_two = create_conversation_run!(execution_target: target)

    first = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run_one)
    second = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run_two)

    assert_equal "acquired", first.fetch(:decision)
    assert_equal "acquired", second.fetch(:decision)
    assert_equal "execution_target", first.fetch(:capacity).fetch("scope_type")
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

  def create_conversation_run!(execution_target: create_execution_target!(max_concurrent_tasks: 1, max_queued_tasks: 2), runtime_governors: nil)
    conversation = create_conversation!
    program = create_program!
    deployment = create_deployment!(program)
    credential =
      LLMProviderCredential.create!(
        provider_key: "openai-#{SecureRandom.hex(4)}",
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
      )
    runtime_governors ||= runtime_governors_snapshot(
      provider_credential: credential,
      selected_model_ref: "openai/gpt-5.4",
      execution_target: execution_target,
    )

    ConversationRun.create!(
      conversation: conversation,
      dag_node_id: SecureRandom.uuid,
      state: "queued",
      queued_at: Time.current.change(usec: 0),
      snapshot_version: 1,
      initiated_by_user: conversation.user,
      effective_permission_mode: "default",
      agent_program: program,
      contract_fingerprint: program.published_contract_fingerprint,
      agent_deployment: deployment,
      deployment_fingerprint: deployment.deployment_fingerprint,
      deployment_activated_at: deployment.activated_at || Time.current.change(usec: 0),
      provider_credential: credential,
      execution_target: execution_target,
      selected_model_ref: "openai/gpt-5.4",
      effective_public_settings: {},
      effective_agent_config: {},
      agent_config_schema_fingerprint: program.config_schema_fingerprint,
      effective_policy: {},
      runtime_governors: runtime_governors,
      snapshot: { "execution_target_id" => execution_target.id },
    )
  end

  def create_execution_target!(max_concurrent_tasks:, max_queued_tasks:, **overrides)
    location =
      ExecutionLocation.create!(
        name: "Fixture host #{SecureRandom.hex(4)}",
        kind: "host",
        platform: "macos_arm64",
        status: "active",
        trust_group: "operator",
        environment: "development",
        tags: ["fixture"],
        max_concurrent_tasks: max_concurrent_tasks,
        max_queued_tasks: max_queued_tasks,
        default_timeout_s: 900,
      )
    workspace =
      Workspace.create!(
        execution_location: location,
        name: "Fixture workspace #{SecureRandom.hex(4)}",
        root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
        workspace_type: "git",
        status: "active",
        capability_tags: ["git"],
        tags: ["fixture"],
      )

    ExecutionTarget.create!(
      {
        execution_location: location,
        workspace: workspace,
        name: "Fixture target",
        status: "active",
        sandboxed: true,
      }.merge(overrides),
    )
  end

  def create_program!
    AgentProgram.create!(
      name: "Fixture Program #{SecureRandom.hex(4)}",
      config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
      manifest_snapshot: {},
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
    )
  end

  def create_deployment!(program)
    AgentDeployment.create!(
      agent_program: program,
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
      supported_methods: AgentDeployments::REQUIRED_METHODS,
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
    )
  end
end
