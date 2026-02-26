require "test_helper"

class DAG::CodexApprovalGateFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class ToolExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      DAG::ExecutionResult.finished(
        payload: { "result" => "ok" },
        usage: { "total_tokens" => 1 }
      )
    end
  end

  class JoinExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = stream

      tool_results =
        context
          .filter_map { |n| n.dig("payload", "output_preview", "result") }
          .map(&:to_s)
          .reject(&:blank?)

      content = tool_results.any? ? "done (tools=#{tool_results.join(",")})" : "done"

      DAG::ExecutionResult.finished(
        payload: { "content" => content },
        usage: { "total_tokens" => 1 }
      )
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "approval gate flow: awaiting_approval blocks execution, deny required does not skip downstream, retry creates a new awaiting_approval attempt, and approve unblocks" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c020"

    user = nil
    tool = nil
    join = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Do a tool call",
          metadata: {}
        )

      tool =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::AWAITING_APPROVAL,
          body_input: { "name" => "test_tool" },
          metadata: {
            "approval" => {
              "required" => true,
              "deny_effect" => "block",
            },
          }
        )

      join =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {}
        )

      m.create_edge(from_node: user, to_node: tool, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: tool, to_node: join, edge_type: DAG::Edge::DEPENDENCY)
    end

    assert_equal [tool.id], graph.awaiting_approval_page.map { |row| row.fetch("node_id") }

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [], claimed

    assert tool.deny_approval!
    tool.reload
    assert_equal DAG::Node::REJECTED, tool.state
    assert_equal "approval_denied", tool.metadata["reason"]

    DAG::FailurePropagation.propagate!(graph: graph)

    join.reload
    assert_equal DAG::Node::PENDING, join.state

    retry_attempt = tool.retry!
    retry_attempt.reload
    assert_equal DAG::Node::AWAITING_APPROVAL, retry_attempt.state

    dependency_parents =
      graph.edges.active
        .where(edge_type: DAG::Edge::DEPENDENCY, to_node_id: join.id)
        .order(:id)
        .pluck(:from_node_id)
    assert_equal [retry_attempt.id], dependency_parents

    assert_equal [retry_attempt.id], graph.awaiting_approval_page.map { |row| row.fetch("node_id") }

    assert retry_attempt.approve!

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, ToolExecutor.new)
    registry.register(Messages::AgentMessage.node_type_key, JoinExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [retry_attempt.id], claimed.map(&:id)
      DAG::Runner.run_node!(retry_attempt.id)
      assert_equal DAG::Node::FINISHED, retry_attempt.reload.state

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [join.id], claimed.map(&:id)
      DAG::Runner.run_node!(join.id)
      assert_equal DAG::Node::FINISHED, join.reload.state

      transcript = graph.transcript_for(join.id)
      assert_equal [user.id, join.id], transcript.map { |n| n.fetch("node_id") }

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
