require "test_helper"

class ConversationRunTest < ActiveSupport::TestCase
  test "stores immutable runtime snapshot fields" do
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
    credential = LLMProviderCredential.create!(provider_key: "fixture-#{SecureRandom.hex(4)}", credential_type: "api_key")
    target = create_execution_target!

    run =
      ConversationRun.create!(
        conversation: conversation,
        dag_node_id: SecureRandom.uuid,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
        snapshot_version: 1,
        initiated_by_user: conversation.user,
        effective_permission_mode: "default",
        agent_program: program,
        contract_fingerprint: "contract:v1",
        agent_deployment: deployment,
        deployment_fingerprint: "deployment:v1",
        deployment_activated_at: Time.current.change(usec: 0),
        provider_credential: credential,
        execution_target: target,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: { "title" => "Fixture" },
        effective_agent_config: { "mode" => "coding" },
        agent_config_schema_fingerprint: "config:v1",
        effective_policy: { "tools" => "allow" },
        runtime_governors: { "provider_key" => "openai" },
        snapshot: { "agent" => { "program_id" => program.id } },
      )

    assert_equal 1, run.snapshot_version
    assert_equal "default", run.effective_permission_mode
    assert_equal "openai/gpt-5.4", run.selected_model_ref
    assert_equal({ "agent" => { "program_id" => program.id } }, run.snapshot)
  end

  test "requires a finalized runtime snapshot for every run" do
    run =
      ConversationRun.new(
        conversation: create_conversation!,
        dag_node_id: SecureRandom.uuid,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
      )

    refute_predicate run, :valid?
    assert_includes run.errors[:snapshot_version], "can't be blank"
    assert_includes run.errors[:effective_permission_mode], "can't be blank"
    assert_includes run.errors[:agent_program], "can't be blank"
    assert_includes run.errors[:contract_fingerprint], "can't be blank"
    assert_includes run.errors[:agent_deployment], "can't be blank"
  end

  test "keeps runtime snapshot fields immutable after creation" do
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

    run =
      ConversationRun.create!(
        conversation: conversation,
        dag_node_id: SecureRandom.uuid,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
        snapshot_version: 1,
        effective_permission_mode: "default",
        agent_program: program,
        contract_fingerprint: "contract:v1",
        agent_deployment: deployment,
        deployment_fingerprint: "deployment:v1",
        deployment_activated_at: Time.current.change(usec: 0),
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {},
        effective_policy: {},
        runtime_governors: {},
        snapshot: { "deployment" => { "fingerprint" => "deployment:v1" } },
      )

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      run.update!(
        contract_fingerprint: "contract:v2",
        deployment_fingerprint: "deployment:v2",
        effective_permission_mode: "full_access",
      )
    end

    run.reload
    assert_equal "contract:v1", run.contract_fingerprint
    assert_equal "deployment:v1", run.deployment_fingerprint
    assert_equal "default", run.effective_permission_mode
  end

  test "state transitions do not rewrite immutable snapshot fields" do
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

    run =
      ConversationRun.create!(
        conversation: conversation,
        dag_node_id: SecureRandom.uuid,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
        snapshot_version: 1,
        effective_permission_mode: "default",
        agent_program: program,
        contract_fingerprint: "contract:v1",
        agent_deployment: deployment,
        deployment_fingerprint: "deployment:v1",
        deployment_activated_at: Time.current.change(usec: 0),
        effective_public_settings: {},
        effective_agent_config: {},
        effective_policy: {},
        runtime_governors: {},
        snapshot: {},
      )

    run.mark_running!

    assert_equal "running", run.reload.state
  end

  test "requires a complete runtime snapshot once snapshot fields are present" do
    run =
      ConversationRun.new(
        conversation: create_conversation!,
        dag_node_id: SecureRandom.uuid,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
        snapshot: { "agent" => { "program" => "fixture" } },
      )

    refute_predicate run, :valid?
    assert_includes run.errors[:snapshot_version], "can't be blank"
    assert_includes run.errors[:effective_permission_mode], "can't be blank"
    assert_includes run.errors[:agent_program], "can't be blank"
    assert_includes run.errors[:contract_fingerprint], "can't be blank"
    assert_includes run.errors[:agent_deployment], "can't be blank"
  end

  test "requires deployment and contract bindings to match the selected program" do
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
    other_program = AgentProgram.create!(
      name: "Other Program",
      config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:v2",
      manifest_snapshot: {},
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:v2",
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

    run =
      ConversationRun.new(
        conversation: conversation,
        dag_node_id: SecureRandom.uuid,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
        snapshot_version: 1,
        effective_permission_mode: "default",
        agent_program: other_program,
        contract_fingerprint: "contract:v2",
        agent_deployment: deployment,
        deployment_fingerprint: "deployment:v1",
        deployment_activated_at: Time.current.change(usec: 0),
        effective_public_settings: {},
        effective_agent_config: {},
        effective_policy: {},
        runtime_governors: {},
        snapshot: {},
      )

    refute_predicate run, :valid?
    assert_includes run.errors[:agent_deployment], "must belong to the selected agent program"
    assert_includes run.errors[:contract_fingerprint], "must match the deployed contract"
  end

  test "rejects draft-only run states" do
    run = ConversationRun.new(conversation: create_conversation!, dag_node_id: SecureRandom.uuid, state: "awaiting_approval", queued_at: Time.current)

    refute_predicate run, :valid?
    assert_includes run.errors[:state], "is not included in the list"
  end

  test "does not expose automation run links" do
    assert_nil ConversationRun.reflect_on_association(:automation_run)
  end

  private

  def create_execution_target!
    location =
      ExecutionLocation.create!(
        name: "Fixture host",
        kind: "host",
        platform: "macos_arm64",
        status: "active",
        trust_group: "operator",
        environment: "development",
        tags: ["fixture"],
        max_concurrent_tasks: 4,
        max_queued_tasks: 16,
        default_timeout_s: 900,
      )
    workspace =
      Workspace.create!(
        execution_location: location,
        name: "Fixture workspace",
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
end
