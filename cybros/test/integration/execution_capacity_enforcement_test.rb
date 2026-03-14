require "test_helper"

class ExecutionCapacityEnforcementTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "scheduler parks blocked runs at claim time for agent-scoped capacity and exposes waiting_for_capacity as a derived runtime state" do
    runtime = create_runtime!(max_concurrent_tasks: 1, max_queued_tasks: 2)
    first = create_queued_execution!(runtime: runtime)
    second = create_queued_execution!(runtime: runtime)

    claimed_first = DAG::Scheduler.claim_executable_nodes(graph: first.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
    claimed_second = DAG::Scheduler.claim_executable_nodes(graph: second.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")

    assert_equal [first.fetch(:node).id], claimed_first.map(&:id)
    assert_equal [], claimed_second.map(&:id)
    assert_equal DAG::Node::RUNNING, first.fetch(:node).reload.state

    parked_node = second.fetch(:node).reload
    parked_run = second.fetch(:run).reload
    parked_wait = RuntimeWait.parked.find_by!(owner_type: "ConversationRun", owner_id: parked_run.id, reason_type: "execution_capacity")

    assert_equal DAG::Node::PENDING, parked_node.state
    assert_equal parked_wait.retry_at.to_i, parked_node.claim_after_at.to_i
    assert_equal "execution_capacity", parked_node.metadata.dig("runtime_wait", "reason_type")
    assert_equal parked_wait.id, parked_node.metadata.dig("runtime_wait", "runtime_wait_id")
    assert_equal "agent", parked_wait.subject_type
    assert_equal runtime.fetch(:agent).id, parked_wait.subject_id
    assert_equal "waiting_for_capacity", parked_run.runtime_state
  end

  test "scheduler terminally fails runs when agent execution backlog is already full" do
    runtime = create_runtime!(max_concurrent_tasks: 1, max_queued_tasks: 1)
    first = create_queued_execution!(runtime: runtime)
    second = create_queued_execution!(runtime: runtime)
    third = create_queued_execution!(runtime: runtime)

    claimed_first = DAG::Scheduler.claim_executable_nodes(graph: first.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
    claimed_second = DAG::Scheduler.claim_executable_nodes(graph: second.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
    claimed_third = DAG::Scheduler.claim_executable_nodes(graph: third.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")

    assert_equal [first.fetch(:node).id], claimed_first.map(&:id)
    assert_equal [], claimed_second.map(&:id)
    assert_equal [], claimed_third.map(&:id)

    failed_node = third.fetch(:node).reload
    failed_run = third.fetch(:run).reload

    assert_equal DAG::Node::ERRORED, failed_node.state
    assert_equal "failed", failed_run.state
    assert_includes failed_node.metadata.fetch("error"), "execution_capacity_denied"
    assert_includes failed_run.error.fetch("message"), "execution_capacity_denied"
    assert_nil RuntimeWait.find_by(owner_type: "ConversationRun", owner_id: failed_run.id, reason_type: "execution_capacity")
  end

  test "releasing capacity resumes the oldest ready parked waiter and retries it promptly for agent-scoped capacity" do
    travel_to(Time.zone.parse("2026-03-09 09:00:00 UTC")) do
      runtime = create_runtime!(max_concurrent_tasks: 1, max_queued_tasks: 2)
      first = create_queued_execution!(runtime: runtime)
      second = create_queued_execution!(runtime: runtime)

      DAG::Scheduler.claim_executable_nodes(graph: first.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
      DAG::Scheduler.claim_executable_nodes(graph: second.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")

      parked_wait =
        RuntimeWait.parked.find_by!(
          owner_type: "ConversationRun",
          owner_id: second.fetch(:run).id,
          reason_type: "execution_capacity",
        )

      assert_enqueued_with(job: DAG::TickGraphJob, args: [second.fetch(:conversation).dag_graph.id, { limit: 10 }]) do
        RuntimeGovernance::ExecutionCapacityEnforcer.release!(conversation_run: first.fetch(:run))
      end

      clear_enqueued_jobs
      assert_enqueued_with(job: DAG::ExecuteNodeJob, args: [second.fetch(:node).id]) do
        DAG::TickGraphJob.perform_now(second.fetch(:conversation).dag_graph.id)
      end

      assert_equal "released", ExecutionCapacityLease.find_by!(execution_request_id: "conversation_run:#{first.fetch(:run).id}").status
      assert_equal "resumed", parked_wait.reload.status
      assert_nil second.fetch(:node).reload.claim_after_at
      assert_nil second.fetch(:node).metadata["runtime_wait"]
      assert_equal DAG::Node::RUNNING, second.fetch(:node).reload.state
    end
  end

  test "canceling a running governed node releases its active execution-capacity lease" do
    runtime = create_runtime!(max_concurrent_tasks: 1, max_queued_tasks: 2)
    execution = create_queued_execution!(runtime: runtime)

    DAG::Scheduler.claim_executable_nodes(graph: execution.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
    execution.fetch(:node).reload.stop!(reason: "user_cancelled")

    execution.fetch(:conversation).send(:cancel_runs_for_node!, execution.fetch(:node).reload)

    assert_equal DAG::Node::STOPPED, execution.fetch(:node).reload.state
    assert_equal "canceled", execution.fetch(:run).reload.state
    assert_equal "released", ExecutionCapacityLease.find_by!(execution_request_id: "conversation_run:#{execution.fetch(:run).id}").status
  end

  test "canceling a parked capacity waiter removes it from the next wakeup selection" do
    runtime = create_runtime!(max_concurrent_tasks: 1, max_queued_tasks: 2)
    first = create_queued_execution!(runtime: runtime)
    second = create_queued_execution!(runtime: runtime)
    third = create_queued_execution!(runtime: runtime)

    DAG::Scheduler.claim_executable_nodes(graph: first.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
    DAG::Scheduler.claim_executable_nodes(graph: second.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
    DAG::Scheduler.claim_executable_nodes(graph: third.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")

    second_wait =
      RuntimeWait.parked.find_by!(
        owner_type: "ConversationRun",
        owner_id: second.fetch(:run).id,
        reason_type: "execution_capacity",
      )
    third_wait =
      RuntimeWait.parked.find_by!(
        owner_type: "ConversationRun",
        owner_id: third.fetch(:run).id,
        reason_type: "execution_capacity",
      )

    second.fetch(:node).reload.stop!(reason: "user_cancelled")
    second.fetch(:conversation).send(:cancel_runs_for_node!, second.fetch(:node).reload)

    assert_equal "cancelled", second_wait.reload.status

    assert_enqueued_with(job: DAG::TickGraphJob, args: [third.fetch(:conversation).dag_graph.id, { limit: 10 }]) do
      RuntimeGovernance::ExecutionCapacityEnforcer.release!(conversation_run: first.fetch(:run))
    end

    assert_equal "resumed", third_wait.reload.status
    assert_equal "canceled", second.fetch(:run).reload.state
  end

  private

    def create_queued_execution!(runtime:)
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
          agent_program: runtime.fetch(:program),
          default_execution_target: nil,
        )
      graph = conversation.dag_graph
      user = graph.nodes.create!(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
      node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      graph.edges.create!(from_node_id: user.id, to_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)

      run =
        ConversationRun.create!(
          conversation: conversation,
          dag_node_id: node.id,
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          snapshot_version: 1,
          initiated_by_user: conversation.user,
          effective_permission_mode: "default",
          agent: runtime.fetch(:agent),
          recognized_deployment: runtime.fetch(:recognized_deployment),
          recognized_deployment_key: runtime.fetch(:recognized_deployment).recognized_deployment_key,
          contract_fingerprint: runtime.fetch(:program).published_contract_fingerprint,
          deployment_fingerprint: runtime.fetch(:deployment).deployment_fingerprint,
          deployment_activated_at: runtime.fetch(:deployment).activated_at || Time.current.change(usec: 0),
          provider_credential: runtime.fetch(:credential),
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: runtime.fetch(:agent).config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: runtime_governors_snapshot(
            provider_credential: runtime.fetch(:credential),
            selected_model_ref: "openai/gpt-5.4",
            agent: runtime.fetch(:agent),
          ),
          snapshot: { "agent" => { "id" => runtime.fetch(:agent).id } },
        )

      assert_nil run[:agent_program_id]
      assert_nil run[:agent_deployment_id]
      assert_nil run[:execution_target_id]

      { conversation: conversation, node: node, run: run }
    end

    def create_runtime!(max_concurrent_tasks:, max_queued_tasks:)
      program = create_program!
      target = create_execution_target!(max_concurrent_tasks: max_concurrent_tasks, max_queued_tasks: max_queued_tasks)
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      deployment = create_deployment!(program)
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
        target: target,
      }
    end

    def create_execution_target!(max_concurrent_tasks:, max_queued_tasks:)
      location =
        create_execution_location_profile!(
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
        name: "Fixture target",
        status: "active",
        sandboxed: true,
      )
    end

    def create_program!
      create_agent_record!(
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
      create_runtime_binding_record!(
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
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end
end
