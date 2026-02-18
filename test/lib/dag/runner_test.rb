require "test_helper"

class DAG::RunnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SkipExecutor
    def execute(node:, context:)
      _ = node
      _ = context
      DAG::ExecutionResult.skipped(reason: "not needed")
    end
  end

  class UsageExecutor
    def execute(node:, context:)
      _ = node
      _ = context

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
    def execute(node:, context:)
      _ = node
      _ = context

      DAG::ExecutionResult.finished(
        payload: { "result" => [1, 2, 3] },
        usage: { "total_tokens" => 1 }
      )
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "runner treats skipped execution results as errors for running nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(DAG::Node::TASK, SkipExecutor.new)

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
    conversation = Conversation.create!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(DAG::Node::AGENT_MESSAGE, UsageExecutor.new)

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
    conversation = Conversation.create!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(DAG::Node::TASK, ToolCallArrayResultExecutor.new)

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
end
