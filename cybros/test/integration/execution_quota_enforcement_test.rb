require "test_helper"

class ExecutionQuotaEnforcementTest < ActiveSupport::TestCase
  test "parks blocked runs and admits them after capacity is released" do
    target = create_execution_target!(max_concurrent_tasks: 1, max_queued_tasks: 2)
    run_one = create_conversation_run!(execution_target: target)
    run_two = create_conversation_run!(execution_target: target)

    first = RuntimeGovernance::ExecutionQuotaEnforcer.admit!(conversation_run: run_one)
    blocked = RuntimeGovernance::ExecutionQuotaEnforcer.admit!(conversation_run: run_two)

    assert_equal "acquired", first.fetch(:decision)
    assert_equal "parked", blocked.fetch(:decision)
    assert_equal 1, ExecutionCapacityLease.active.count

    wait = blocked.fetch(:runtime_wait)
    assert_equal "execution_quota", wait.reason_type
    assert_equal "ConversationRun", wait.owner_type
    assert_equal run_two.id, wait.owner_id
    assert_equal "conversation_run:#{run_two.id}", wait.details.fetch("execution_request_id")

    RuntimeGovernance::ExecutionQuotaEnforcer.release!(conversation_run: run_one)

    replay = RuntimeGovernance::ExecutionQuotaEnforcer.admit!(conversation_run: run_two)

    assert_equal "acquired", replay.fetch(:decision)
    assert_equal "conversation_run:#{run_two.id}", replay.fetch(:execution_request_id)
    assert_equal 0, RuntimeWait.parked.where(reason_type: "execution_quota", owner_type: "ConversationRun", owner_id: run_two.id).count
  end

  private

  def create_conversation_run!(execution_target:)
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
      runtime_governors: {
        "execution_quota" => RuntimeGovernance::ExecutionQuotaResolver.resolve!(execution_target: execution_target),
      },
      snapshot: { "execution_target_id" => execution_target.id },
    )
  end

  def create_execution_target!(max_concurrent_tasks:, max_queued_tasks:)
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
      execution_location: location,
      workspace: workspace,
      name: "Fixture target",
      status: "active",
      sandboxed: true,
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
      supported_methods: %w[initialize turn.prepare turn.compose],
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
    )
  end
end
