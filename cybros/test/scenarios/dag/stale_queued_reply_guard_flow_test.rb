require "test_helper"

class DAG::StaleQueuedReplyGuardFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class StaleGuardExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      expected_tail_anchor = node.metadata["expected_tail_anchor_node_id"].to_s
      lane = node.lane

      tail_turn_id =
        lane.anchored_turn_page(limit: 1, include_deleted: false).fetch("turns").last&.fetch("turn_id", nil).to_s

      actual_tail_anchor =
        if tail_turn_id.present?
          lane.turns.find(tail_turn_id).start_message_node_id(include_deleted: false).to_s
        else
          ""
        end

      if expected_tail_anchor.present? && actual_tail_anchor.present? && actual_tail_anchor != expected_tail_anchor
        return DAG::ExecutionResult.stopped(
          reason: nil,
          metadata: {
            "stale" => true,
            "stale_reason" => "expected_tail_anchor_mismatch",
            "expected_tail_anchor_node_id" => expected_tail_anchor,
            "actual_tail_anchor_node_id" => actual_tail_anchor,
          },
          usage: { "total_tokens" => 0 }
        )
      end

      reply = node.metadata["reply"].to_s
      DAG::ExecutionResult.finished(payload: { "content" => reply }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "stale queued reply guard: stale pending agent reply can stop silently based on lane tail anchor and not pollute subsequent context" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_1 = "0194f3c0-0000-7000-8000-00000000e301"
    turn_2 = "0194f3c0-0000-7000-8000-00000000e302"

    user_1 = nil
    agent_stale = nil

    graph.mutate!(turn_id: turn_1) do |m|
      user_1 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f301",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "u1",
          metadata: {}
        )
      agent_stale =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f302",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {
            "reply" => "a1(stale)",
            "expected_tail_anchor_node_id" => user_1.id,
          }
        )
      m.create_edge(from_node: user_1, to_node: agent_stale, edge_type: DAG::Edge::SEQUENCE)
    end

    user_2 = nil
    agent_2 = nil

    graph.mutate!(turn_id: turn_2) do |m|
      user_2 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f303",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "u2",
          metadata: {}
        )
      agent_2 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f304",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {
            "reply" => "a2",
            "expected_tail_anchor_node_id" => user_2.id,
          }
        )

      m.create_edge(from_node: user_1, to_node: user_2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user_2, to_node: agent_2, edge_type: DAG::Edge::SEQUENCE)
    end

    tail_turn = lane.anchored_turn_page(limit: 1, include_deleted: false).fetch("turns").sole
    assert_equal turn_2, tail_turn.fetch("turn_id")

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, StaleGuardExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 1, claimed_by: "test")
      assert_equal [agent_stale.id], claimed.map(&:id)
      assert_equal DAG::Node::RUNNING, agent_stale.reload.state

      DAG::Runner.run_node!(agent_stale.id)
      agent_stale.reload
      assert_equal DAG::Node::STOPPED, agent_stale.state
      assert_nil agent_stale.metadata["reason"], "silent stop should not add a transcript-visible reason"
      assert_equal true, agent_stale.metadata["stale"]

      agent_stale.exclude_from_context!
      assert agent_stale.reload.context_excluded?

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 1, claimed_by: "test")
      assert_equal [agent_2.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent_2.id)
      assert_equal DAG::Node::FINISHED, agent_2.reload.state
      assert_equal "a2", agent_2.body_output["content"]

      context = lane.context_for(agent_2.id)
      assert_equal [user_1.id, user_2.id, agent_2.id], context.map { |n| n.fetch("node_id") }

      transcript_page = lane.transcript_page(limit_turns: 10)
      contents =
        transcript_page.fetch("transcript").map do |node|
          node.dig("payload", "input", "content").to_s.presence ||
            node.dig("payload", "output_preview", "content").to_s
        end
      assert_equal %w[u1 u2 a2], contents

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
