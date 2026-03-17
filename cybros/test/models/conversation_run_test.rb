require "test_helper"

class ConversationRunTest < ActiveSupport::TestCase
  test "stores recognized deployment bindings in the immutable runtime snapshot" do
    run = ConversationRun.new

    assert_equal :recognized_deployment, ConversationRun.reflect_on_association(:recognized_deployment)&.name
    assert_nil ConversationRun.reflect_on_association(:agent_deployment)
    assert_nil ConversationRun.reflect_on_association(:execution_target)
    assert_includes ConversationRun.attribute_names, "recognized_deployment_id"
    assert_includes ConversationRun.attribute_names, "recognized_deployment_key"
    assert_includes ConversationRun::SNAPSHOT_FIELDS, :recognized_deployment_id
    assert_includes ConversationRun::SNAPSHOT_FIELDS, :recognized_deployment_key
    refute_respond_to run, :agent_program
    refute_respond_to run, :agent_deployment
    refute_respond_to run, :execution_target
  end

  test "stores immutable runtime snapshot fields" do
    runtime = create_runtime!
    conversation = create_conversation!(agent: runtime.fetch(:agent), agent_program: runtime.fetch(:program))
    run = build_run(runtime: runtime, conversation: conversation)

    assert_predicate run, :valid?
    run.save!

    assert_equal runtime.fetch(:agent).id, run.agent_id
    assert_equal runtime.fetch(:recognized_deployment).id, run.recognized_deployment_id
    assert_equal runtime.fetch(:recognized_deployment).recognized_deployment_key, run.recognized_deployment_key
    assert_nil run[:agent_program_id]
    assert_nil run[:agent_deployment_id]
    assert_nil run[:execution_target_id]
    assert_equal 1, run.snapshot_version
    assert_equal "default", run.effective_permission_mode
    assert_equal "openai/gpt-5.4", run.selected_model_ref
    assert_equal({ "agent" => { "id" => runtime.fetch(:agent).id } }, run.snapshot)
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
    assert_includes run.errors[:recognized_deployment], "can't be blank"
    assert_includes run.errors[:recognized_deployment_key], "can't be blank"
    assert_includes run.errors[:contract_fingerprint], "can't be blank"
  end

  test "requires a provider governor snapshot when a model or credential is selected" do
    runtime = create_runtime!
    run = build_run(runtime: runtime, runtime_governors: {})

    refute_predicate run, :valid?
    assert_includes run.errors[:runtime_governors], "must include a provider_limiter snapshot"
  end

  test "requires an execution governor snapshot when an agent is selected" do
    runtime = create_runtime!
    run =
      build_run(
        runtime: runtime,
        runtime_governors: {
          "provider_limiter" => {
            "provider_key" => "openai",
            "provider_credential_id" => runtime.fetch(:provider_credential).id,
          },
        },
      )

    refute_predicate run, :valid?
    assert_includes run.errors[:runtime_governors], "must include an execution_capacity snapshot"
  end

  test "requires recognized deployments to belong to the selected agent" do
    runtime = create_runtime!
    other_runtime = create_runtime!(namespace: "fixture.other")
    run =
      build_run(
        runtime: runtime,
        recognized_deployment: other_runtime.fetch(:recognized_deployment),
        recognized_deployment_key: other_runtime.fetch(:recognized_deployment).recognized_deployment_key,
      )

    refute_predicate run, :valid?
    assert_includes run.errors[:recognized_deployment], "must belong to the selected agent"
  end

  test "snapshot accessors prefer persisted runtime ids over live recognized deployment pointers" do
    runtime = create_runtime!
    run = build_run(runtime: runtime)
    run.save!
    original_deployment_fingerprint = run.deployment_fingerprint
    replacement =
      create_deployment!(
        runtime.fetch(:program),
        deployment_fingerprint: "deployment:replacement",
        status: "inactive",
        health_status: "unknown",
      )

    runtime.fetch(:recognized_deployment).update!(deployment_fingerprint: replacement.deployment_fingerprint)

    assert_nil run[:agent_program_id]
    assert_nil run[:agent_deployment_id]
    assert_equal original_deployment_fingerprint, run.deployment_fingerprint
  end

  test "keeps runtime snapshot fields immutable after creation" do
    runtime = create_runtime!
    run = build_run(runtime: runtime)
    run.save!

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      run.update!(
        contract_fingerprint: "contract:v2",
        deployment_fingerprint: "deployment:v2",
        effective_permission_mode: "full_access",
      )
    end

    run.reload
    assert_equal "contract:v1", run.contract_fingerprint
    assert_equal runtime.fetch(:deployment).deployment_fingerprint, run.deployment_fingerprint
    assert_equal "default", run.effective_permission_mode
  end

  test "latest_for_node falls back to the same-turn agent run for task nodes" do
    runtime = create_runtime!
    conversation = create_conversation!(agent: runtime.fetch(:agent), agent_program: runtime.fetch(:program))
    agent_node =
      conversation.root_graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::PENDING,
        lane_id: conversation.chat_lane.id,
        turn_id: SecureRandom.uuid,
        metadata: {},
      )
    task_node =
      conversation.root_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::PENDING,
        lane_id: conversation.chat_lane.id,
        turn_id: agent_node.turn_id,
        metadata: {},
        body_input: {
          "name" => "compact_context",
          "requested_name" => "compact_context",
          "tool_call_id" => "tc_1",
          "arguments" => { "reason" => "test" },
          "arguments_summary" => "{\"reason\":\"test\"}",
        },
      )
    run = build_run(runtime: runtime, conversation: conversation, dag_node_id: agent_node.id)
    run.save!

    assert_equal run, ConversationRun.latest_for_node(task_node)
  end

  test "state transitions do not rewrite immutable snapshot fields" do
    runtime = create_runtime!
    run = build_run(runtime: runtime)
    run.save!

    run.mark_running!

    assert_equal "running", run.reload.state
    assert_equal runtime.fetch(:recognized_deployment).recognized_deployment_key, run.recognized_deployment_key
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

    def build_run(attributes = {})
      runtime = attributes.delete(:runtime) || create_runtime!
      conversation =
        if attributes.key?(:conversation)
          attributes.delete(:conversation)
        else
          create_conversation!(
            agent: runtime.fetch(:agent),
            agent_program: runtime.fetch(:program),
            default_execution_target: nil,
          )
        end
      recognized_deployment =
        if attributes.key?(:recognized_deployment)
          attributes.delete(:recognized_deployment)
        else
          runtime.fetch(:recognized_deployment)
        end
      recognized_deployment_key = attributes.delete(:recognized_deployment_key) || recognized_deployment&.recognized_deployment_key
      runtime_governors =
        if attributes.key?(:runtime_governors)
          attributes.delete(:runtime_governors)
        else
          runtime_governors_snapshot(
            provider_credential: runtime.fetch(:provider_credential),
            selected_model_ref: "openai/gpt-5.4",
            agent: runtime.fetch(:agent),
          )
        end

      ConversationRun.new(
        {
          conversation: conversation,
          dag_node_id: SecureRandom.uuid,
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          snapshot_version: 1,
          initiated_by_user: conversation.user,
          effective_permission_mode: "default",
          agent: runtime.fetch(:agent),
          recognized_deployment: recognized_deployment,
          recognized_deployment_key: recognized_deployment_key,
          contract_fingerprint: runtime.fetch(:deployment).contract_fingerprint,
          deployment_fingerprint: runtime.fetch(:deployment).deployment_fingerprint,
          deployment_activated_at: runtime.fetch(:deployment).activated_at,
          provider_credential: runtime.fetch(:provider_credential),
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: runtime.fetch(:agent).config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: runtime_governors,
          snapshot: { "agent" => { "id" => runtime.fetch(:agent).id } },
        }.merge(attributes),
      )
    end

    def create_runtime!(namespace: "fixture.program")
      program =
        create_agent_record!(
          name: "Fixture Program #{SecureRandom.hex(4)}",
          config_namespace: "#{namespace}.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_key" => "fixture-program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      target = create_execution_target!
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      deployment = create_deployment!(program)
      recognized_deployment =
        Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
          agent: agent,
          deployment: deployment,
          initialize_result: {
            "identity" => {
              "agent_key" => program.manifest_snapshot["agent_key"],
              "deployment_fingerprint" => deployment.deployment_fingerprint,
              "protocol_version" => deployment.protocol_version,
              "agent_sdk_version" => deployment.agent_sdk_version,
              "supported_methods" => deployment.supported_methods,
            },
          },
          capability_snapshot: deployment.capability_snapshot,
        )
      provider_credential =
        ensure_llm_provider!(
          provider_key: "openai",
          credential_type: "api_key",
          status: "active",
          api_key: "sk-test",
        )

      {
        agent: agent,
        deployment: deployment,
        program: program,
        provider_credential: provider_credential,
        recognized_deployment: recognized_deployment,
        target: target,
      }
    end

    def create_deployment!(program, deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}", status: "active", health_status: "healthy")
      create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: status,
        health_status: health_status,
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: { "agent_capabilities_version" => "2026-03-13" },
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_execution_target!
      location =
        create_execution_location_profile!(
          name: "Fixture host #{SecureRandom.hex(4)}",
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
        create_workspace_profile!(
          execution_location: location,
          name: "Fixture workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      create_execution_profile!(
        execution_location: location,
        workspace: workspace,
        name: "Fixture target #{SecureRandom.hex(4)}",
        status: "active",
        sandboxed: true,
      )
    end
end
