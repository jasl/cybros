require "test_helper"

class DAG::UserInputWhileRunningFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FixedReplyExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      reply = node.metadata["reply"].to_s
      DAG::ExecutionResult.finished(payload: { "content" => reply }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "user input while agent running: queue policy blocks the next reply until the running reply finishes" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_1 = "0194f3c0-0000-7000-8000-00000000e101"
    turn_2 = "0194f3c0-0000-7000-8000-00000000e102"

    user_1 = nil
    agent_1 = nil

    graph.mutate!(turn_id: turn_1) do |m|
      user_1 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f101",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "u1",
          metadata: {}
        )
      agent_1 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f102",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "reply" => "a1" }
        )
      m.create_edge(from_node: user_1, to_node: agent_1, edge_type: DAG::Edge::SEQUENCE)
    end

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent_1.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, agent_1.reload.state

    user_2 = nil
    agent_2 = nil

    graph.mutate!(turn_id: turn_2) do |m|
      user_2 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f103",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "u2",
          metadata: {}
        )
      agent_2 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f104",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "reply" => "a2" }
        )
      m.create_edge(from_node: user_2, to_node: agent_2, edge_type: DAG::Edge::SEQUENCE)

      # Queue policy: the next reply is blocked until the in-flight reply finishes.
      m.create_edge(
        from_node: agent_1,
        to_node: agent_2,
        edge_type: DAG::Edge::DEPENDENCY,
        metadata: { "generated_by" => "queue_policy" }
      )
    end

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [], claimed.map(&:id), "agent_2 must not be claimable while agent_1 is running"

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, FixedReplyExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      DAG::Runner.run_node!(agent_1.id)
      assert_equal DAG::Node::FINISHED, agent_1.reload.state

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent_2.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent_2.id)
      assert_equal DAG::Node::FINISHED, agent_2.reload.state

      transcript_page = lane.transcript_page(limit_turns: 10)
      contents =
        transcript_page.fetch("transcript").map do |node|
          node.dig("payload", "input", "content").to_s.presence ||
            node.dig("payload", "output_preview", "content").to_s
        end
      assert_equal %w[u1 a1 u2 a2], contents

      context = lane.context_for(agent_2.id)
      assert_equal [user_1.id, agent_1.id, user_2.id, agent_2.id], context.map { |n| n.fetch("node_id") }

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end

  test "user input while agent running: restart policy stops the in-flight reply and excludes it from context" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_1 = "0194f3c0-0000-7000-8000-00000000e201"
    turn_2 = "0194f3c0-0000-7000-8000-00000000e202"

    user_1 = nil
    agent_1 = nil

    graph.mutate!(turn_id: turn_1) do |m|
      user_1 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f201",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "u1",
          metadata: {}
        )
      agent_1 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f202",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "reply" => "a1" }
        )
      m.create_edge(from_node: user_1, to_node: agent_1, edge_type: DAG::Edge::SEQUENCE)
    end

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent_1.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, agent_1.reload.state

    assert agent_1.stop!(reason: "restart_by_user")
    agent_1.reload
    assert_equal DAG::Node::STOPPED, agent_1.state

    agent_1.exclude_from_context!
    assert agent_1.reload.context_excluded?

    user_2 = nil
    agent_2 = nil

    graph.mutate!(turn_id: turn_2) do |m|
      user_2 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f203",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "u2",
          metadata: {}
        )
      agent_2 =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f204",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "reply" => "a2" }
        )

      m.create_edge(from_node: user_1, to_node: user_2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user_2, to_node: agent_2, edge_type: DAG::Edge::SEQUENCE)
    end

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, FixedReplyExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent_2.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent_2.id)
      assert_equal DAG::Node::FINISHED, agent_2.reload.state

      transcript_page = lane.transcript_page(limit_turns: 10)
      contents =
        transcript_page.fetch("transcript").map do |node|
          node.dig("payload", "input", "content").to_s.presence ||
            node.dig("payload", "output_preview", "content").to_s
        end
      assert_equal ["u1", "Stopped: restart_by_user", "u2", "a2"], contents

      context = lane.context_for(agent_2.id)
      context_ids = context.map { |n| n.fetch("node_id") }
      assert_equal [user_1.id, user_2.id, agent_2.id], context_ids
      refute_includes context_ids, agent_1.id

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
