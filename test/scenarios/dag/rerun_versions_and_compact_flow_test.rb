require "test_helper"

class DAG::RerunVersionsAndCompactFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class IntentAwareAgentExecutor
    def execute(node:, context:)
      _ = context

      intent = node.metadata["rerun_intent"].to_s
      graph = node.graph

      graph.mutate!(turn_id: node.turn_id) do |m|
        tool_1 =
          m.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::FINISHED,
            idempotency_key: "tool1",
            body_input: { "name" => "tool1" },
            body_output: { "result" => "ok1" },
            metadata: {}
          )

        m.create_edge(from_node: tool_1, to_node: node, edge_type: DAG::Edge::SEQUENCE, metadata: { "generated_by" => "executor" })

        if intent == "rerun"
          tool_2 =
            m.create_node(
              node_type: Messages::Task.node_type_key,
              state: DAG::Node::FINISHED,
              idempotency_key: "tool2",
              body_input: { "name" => "tool2" },
              body_output: { "result" => "ok2" },
              metadata: {}
            )

          m.create_edge(from_node: tool_2, to_node: node, edge_type: DAG::Edge::SEQUENCE, metadata: { "generated_by" => "executor" })
        end
      end

      content =
        case intent
        when "rewrite"
          "v2 rewrite"
        when "rerun"
          "v3 rerun"
        else
          "v1"
        end

      DAG::ExecutionResult.finished(payload: { "content" => content }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "product flow: rerun versions, adopt, and compact the turn context" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane
    turn_id = "0194f3c0-0000-7000-8000-00000000f010"

    user = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
    end

    v1 = graph.nodes.active.find_by!(turn_id: turn_id, node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, IntentAwareAgentExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [v1.id], claimed.map(&:id)
      DAG::Runner.run_node!(v1.id)
      assert_equal DAG::Node::FINISHED, v1.reload.state

      tool_1 = graph.nodes.active.find_by!(turn_id: turn_id, node_type: Messages::Task.node_type_key, idempotency_key: "tool1")
      assert_equal lane.id, tool_1.lane_id
      assert_nil graph.nodes.active.find_by(turn_id: turn_id, node_type: Messages::Task.node_type_key, idempotency_key: "tool2")

      v2 = v1.rerun!(metadata_patch: { "rerun_intent" => "rewrite" })
      assert_equal v1.version_set_id, v2.version_set_id

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [v2.id], claimed.map(&:id)
      DAG::Runner.run_node!(v2.id)
      assert_equal DAG::Node::FINISHED, v2.reload.state

      assert_nil graph.nodes.active.find_by(turn_id: turn_id, node_type: Messages::Task.node_type_key, idempotency_key: "tool2")

      v3 = v2.rerun!(metadata_patch: { "rerun_intent" => "rerun" })

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [v3.id], claimed.map(&:id)
      DAG::Runner.run_node!(v3.id)
      assert_equal DAG::Node::FINISHED, v3.reload.state

      tool_2 = graph.nodes.active.find_by!(turn_id: turn_id, node_type: Messages::Task.node_type_key, idempotency_key: "tool2")
      assert_equal lane.id, tool_2.lane_id

      assert_equal 3, v3.version_count
      assert_equal [v3.id], graph.nodes.active.where(version_set_id: v3.version_set_id).pluck(:id)

      adopted = v1.reload.adopt_version!
      assert_equal v1.id, adopted.id
      assert_equal [v1.id], graph.nodes.active.where(version_set_id: v1.version_set_id).pluck(:id)

      assert tool_2.reload.compressed_at.present?

      lane.compact_turn_context!(turn_id: turn_id, keep_node_ids: [user.id, adopted.id])

      context_ids = graph.context_for(adopted.id).map { |node| node.fetch("node_id") }
      assert_equal [user.id, adopted.id], context_ids

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
