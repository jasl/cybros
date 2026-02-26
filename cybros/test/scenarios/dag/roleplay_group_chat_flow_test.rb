require "test_helper"

class DAG::RoleplayGroupChatFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class CharacterExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      actor = node.metadata["actor"].to_s
      content =
        case actor
        when "alice"
          "Alice: hello"
        when "bob"
          "Bob: hello"
        else
          "#{actor}: hello"
        end

      DAG::ExecutionResult.finished(payload: { "content" => content }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "roleplay flow: multiple executable character_message nodes in one turn, rerun, and transcript views" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c020"

    user = nil
    alice = nil
    bob = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Start", metadata: {})
      alice = m.create_node(node_type: Messages::CharacterMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "actor" => "alice" })
      bob = m.create_node(node_type: Messages::CharacterMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "actor" => "bob" })

      m.create_edge(from_node: user, to_node: alice, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: bob, edge_type: DAG::Edge::SEQUENCE)
    end

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::CharacterMessage.node_type_key, CharacterExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [alice.id, bob.id].sort, claimed.map(&:id).sort

      DAG::Runner.run_node!(alice.id)
      DAG::Runner.run_node!(bob.id)

      transcript = graph.transcript_recent_turns(limit_turns: 1)
      transcript_types = transcript.map { |node| node.fetch("node_type") }
      assert_equal [Messages::UserMessage.node_type_key, Messages::CharacterMessage.node_type_key, Messages::CharacterMessage.node_type_key], transcript_types

      rerun_alice = alice.reload.rerun!
      assert_equal Messages::CharacterMessage.node_type_key, rerun_alice.node_type
      assert_equal DAG::Node::PENDING, rerun_alice.state
      assert_equal alice.turn_id, rerun_alice.turn_id

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [rerun_alice.id], claimed.map(&:id)
      DAG::Runner.run_node!(rerun_alice.id)

      recent = graph.transcript_recent_turns(limit_turns: 1)
      node_ids = recent.map { |node| node.fetch("node_id") }
      assert_includes node_ids, rerun_alice.id
      assert_includes node_ids, bob.id
      refute_includes node_ids, alice.id

      thread_view = graph.transcript_for(rerun_alice.id)
      assert_equal [user.id, rerun_alice.id], thread_view.map { |node| node.fetch("node_id") }

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
