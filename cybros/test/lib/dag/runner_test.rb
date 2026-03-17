require "test_helper"

class DAG::RunnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SkipExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream
      DAG::ExecutionResult.skipped(reason: "not needed")
    end
  end

  class UsageExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream

      DAG::ExecutionResult.finished(
        payload: { "content" => "ok" },
        usage: {
          "provider" => "test",
          "model" => "gpt-test",
          "prompt_tokens" => 1,
          "completion_tokens" => 2,
          "total_tokens" => 3,
        }
      )
    end
  end

  class ToolCallArrayResultExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream

      DAG::ExecutionResult.finished(
        payload: { "result" => [1, 2, 3] },
        usage: { "total_tokens" => 1 }
      )
    end
  end

  class ErrorResultExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream

      DAG::ExecutionResult.errored(error: "boom")
    end
  end

  class StopMidStreamExecutor
    def execute(node:, context:, stream:)
      _ = context

      stream.output_delta!("hel")
      node.stop!(reason: "stopped_by_user")

      DAG::ExecutionResult.finished_streamed(
        usage: { "total_tokens" => 1 }
      )
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "runner treats skipped execution results as errors for running nodes" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, SkipExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    assert_equal DAG::Node::ERRORED, node.reload.state
    assert_includes node.metadata.fetch("error"), "skipped_for_running_node"
    assert_enqueued_with(job: DAG::TickGraphJob, args: [graph.id])
  ensure
    DAG.executor_registry = original_registry
  end

  test "runner writes usage and output_stats for finished nodes" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, UsageExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    node.reload
    assert_equal DAG::Node::FINISHED, node.state
    assert node.started_at.present?
    assert node.heartbeat_at.present?
    assert node.lease_expires_at.present?
    assert_equal 3, node.metadata.dig("usage", "total_tokens")
    assert_kind_of Integer, node.metadata.dig("output_stats", "body_output_bytes")
    assert_kind_of Integer, node.metadata.dig("timing", "run_duration_ms")
  ensure
    DAG.executor_registry = original_registry
  end

  test "runner executes character_message nodes and writes usage/output_stats" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::CharacterMessage.node_type_key, state: DAG::Node::RUNNING, metadata: { "actor" => "npc" })

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::CharacterMessage.node_type_key, UsageExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    node.reload
    assert_equal DAG::Node::FINISHED, node.state
    assert node.started_at.present?
    assert node.heartbeat_at.present?
    assert node.lease_expires_at.present?
    assert_equal 3, node.metadata.dig("usage", "total_tokens")
    assert_kind_of Integer, node.metadata.dig("output_stats", "body_output_bytes")
  ensure
    DAG.executor_registry = original_registry
  end

  test "output_stats includes array result shape for tool calls" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, ToolCallArrayResultExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    node.reload
    assert_equal DAG::Node::FINISHED, node.state
    assert_equal "array", node.metadata.dig("output_stats", "result_type")
    assert_equal 3, node.metadata.dig("output_stats", "result_array_len")
  ensure
    DAG.executor_registry = original_registry
  end

  test "runner records queue latency and execute_job_id when node is claimed" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: node.id, edge_type: DAG::Edge::DEPENDENCY)

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, UsageExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test").first
    assert_equal node.id, claimed.id

    DAG::Runner.run_node!(node.id, execute_job_id: "job-123")

    node.reload
    assert_equal DAG::Node::FINISHED, node.state
    assert_kind_of Integer, node.metadata.dig("timing", "queue_latency_ms")
    assert_kind_of Integer, node.metadata.dig("timing", "run_duration_ms")
    assert_equal "job-123", node.metadata.dig("worker", "execute_job_id")
  ensure
    DAG.executor_registry = original_registry
  end

  test "runner marks matching queued conversation run as succeeded" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    run =
      create_conversation_run!(conversation: conversation, dag_node_id: node.id)

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, UsageExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    assert_equal "succeeded", run.reload.state
    assert run.started_at.present?
    assert run.finished_at.present?
  ensure
    DAG.executor_registry = original_registry
  end

  test "runner marks matching queued conversation run as failed with error payload" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    run =
      create_conversation_run!(conversation: conversation, dag_node_id: node.id)

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, ErrorResultExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    assert_equal "failed", run.reload.state
    assert run.started_at.present?
    assert run.finished_at.present?
    assert_equal "boom", run.error["message"]
  ensure
    DAG.executor_registry = original_registry
  end

  test "runner can skip follow-up graph enqueue for synchronous execution paths" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, UsageExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id, enqueue_follow_up: false)

    assert_equal DAG::Node::FINISHED, node.reload.state
    assert_no_enqueued_jobs only: DAG::TickGraphJob
  ensure
    DAG.executor_registry = original_registry
  end

  test "runner does not override a node that was stopped mid-stream, and stop materializes partial output" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    run =
      create_conversation_run!(conversation: conversation, dag_node_id: node.id)

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, StopMidStreamExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    node.reload
    assert_equal DAG::Node::STOPPED, node.state
    assert_equal "hel", node.body_output["content"]
    assert_equal "hel", node.body_output_preview["content"]

    deltas = graph.node_event_page_for(node.id, kinds: [DAG::NodeEvent::OUTPUT_DELTA])
    assert_equal [], deltas

    compacted = graph.node_event_page_for(node.id, kinds: [DAG::NodeEvent::OUTPUT_COMPACTED])
    assert_equal 1, compacted.length
    assert_equal 1, compacted.first.dig("payload", "chunks")
    assert_equal "hel".bytesize, compacted.first.dig("payload", "bytes")
    assert_equal Digest::SHA256.hexdigest("hel"), compacted.first.dig("payload", "sha256")
    assert_equal "canceled", run.reload.state

    assert_enqueued_with(job: DAG::TickGraphJob, args: [graph.id])
  ensure
    DAG.executor_registry = original_registry
  end

  private

    def create_conversation_run!(conversation:, dag_node_id:)
      program = create_program!
      deployment = create_deployment!(program)
      agent = create_agent_runtime!(agent: program, execution_profile: build_default_execution_profile!, deployment: deployment)
      conversation.update!(agent: agent, agent_config_schema_fingerprint: program.config_schema_fingerprint)
      recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)

      ConversationRun.create!(
        build_conversation_run_attributes(
          conversation: conversation,
          dag_node_id: dag_node_id,
          agent: agent,
          recognized_deployment: recognized_deployment,
          effective_permission_mode: conversation.permission_mode,
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: program.config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: runtime_governors_snapshot(selected_model_ref: "openai/gpt-5.4", agent: agent),
          snapshot: { "origin" => "dag_runner_test" },
          error: {},
        ).merge(debug: {}),
      )
    end

    def create_program!
      create_agent_record!(
        name: "Runner Fixture Program #{SecureRandom.hex(4)}",
        config_namespace: "dag.runner.fixture.#{SecureRandom.hex(4)}",
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
