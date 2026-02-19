require "test_helper"

class DAG::OpencodePlanModeOptionalApprovalFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class PlanThenFinalExecutor
    def execute(node:, context:, stream:)
      _ = stream

      phase = node.metadata["phase"].to_s

      case phase
      when "plan"
        create_optional_tool_call_and_final(node)
        DAG::ExecutionResult.finished(payload: {}, usage: { "total_tokens" => 1 })
      when "final"
        tool = context.find { |n| n.fetch("node_type") == Messages::Task.node_type_key }

        content =
          if tool&.fetch("state") == DAG::Node::FINISHED
            tool_preview = tool.dig("payload", "output_preview", "result").to_s
            "Final (tool=ok) #{tool_preview}"
          else
            tool_state = tool&.fetch("state").to_s
            "Final (tool=#{tool_state.presence || "missing"})"
          end

        DAG::ExecutionResult.finished(payload: { "content" => content }, usage: { "total_tokens" => 1 })
      else
        DAG::ExecutionResult.errored(error: "unknown_phase=#{phase}")
      end
    end

    private

    def create_optional_tool_call_and_final(node)
      graph = node.graph

      graph.mutate!(turn_id: node.turn_id) do |m|
        tool =
          m.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::AWAITING_APPROVAL,
            idempotency_key: "bash_ls",
            body_input: { "name" => "bash", "command" => "ls -la" },
            metadata: { "approval" => { "required" => false } }
          )

        final =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            idempotency_key: "final_answer",
            metadata: { "phase" => "final" }
          )

        m.create_edge(from_node: node, to_node: tool, edge_type: DAG::Edge::SEQUENCE)
        m.create_edge(from_node: tool, to_node: final, edge_type: DAG::Edge::SEQUENCE)
      end
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "opencode plan-mode flow: ask permission for tool, deny, and still produce final via sequence edge" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d200"

    user = nil
    planner = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Inspect repo", metadata: {})
      planner = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "phase" => "plan" })
      m.create_edge(from_node: user, to_node: planner, edge_type: DAG::Edge::SEQUENCE)
    end

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, PlanThenFinalExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [planner.id], claimed.map(&:id)
      DAG::Runner.run_node!(planner.id)
      assert_equal DAG::Node::FINISHED, planner.reload.state

      awaiting = graph.awaiting_approval_page(limit: 10)
      assert_equal 1, awaiting.length
      tool_id = awaiting.first.fetch("node_id")

      tool = graph.nodes.find(tool_id)
      assert_equal DAG::Node::AWAITING_APPROVAL, tool.state

      # Deny the optional tool call. Since the final node depends on it via a
      # sequence edge (not dependency), the graph should still proceed.
      assert tool.deny_approval!
      assert_equal DAG::Node::REJECTED, tool.reload.state

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal 1, claimed.length

      final = claimed.sole
      assert_equal Messages::AgentMessage.node_type_key, final.node_type
      assert_equal({ "phase" => "final" }, final.metadata.slice("phase"))

      DAG::Runner.run_node!(final.id)
      final.reload
      assert_equal DAG::Node::FINISHED, final.state
      assert_includes final.body_output["content"].to_s, "Final (tool=rejected)"

      transcript = graph.transcript_for(final.id)
      assert_equal [user.id, final.id], transcript.map { |n| n.fetch("node_id") }

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end

