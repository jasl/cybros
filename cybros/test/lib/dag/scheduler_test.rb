require "test_helper"
require "thread"

class DAG::SchedulerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    Event.delete_all
    DAG::Edge.delete_all
    DAG::Node.delete_all
    DAG::NodeBody.delete_all
    DAG::Graph.delete_all
    Conversation.delete_all
  end

  test "claim_executable_nodes claims pending executable nodes whose blocking parents are finished" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    child = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [child.id], claimed.map(&:id)
    child.reload
    assert_equal DAG::Node::RUNNING, child.state
    assert_nil child.started_at
    assert_equal "test", child.claimed_by
    assert child.claimed_at.present?
    assert child.lease_expires_at.present?

    event = conversation.events.find_by!(event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED, subject: child)
    assert_equal({ "from" => "pending", "to" => "running" }, event.particulars)
  end

  test "claim_executable_nodes claims pending character_message nodes" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    child = graph.nodes.create!(node_type: Messages::CharacterMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "actor" => "npc" })
    graph.edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [child.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, child.reload.state
  end

  test "claim_executable_nodes does not claim nodes blocked by non-finished parents" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, metadata: {})
    child = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [], claimed
    assert_equal DAG::Node::PENDING, child.reload.state
  end

  test "claim_executable_nodes claims nodes blocked only by sequence edges whose parents are terminal" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, metadata: {})
    child = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::SEQUENCE)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [child.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, child.reload.state
  end

  test "claim_executable_nodes ignores dirty dependency edges whose parents belong to another graph" do
    conversation_a = create_conversation!
    graph_a = conversation_a.dag_graph

    conversation_b = create_conversation!
    graph_b = conversation_b.dag_graph

    dirty_parent = graph_b.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, metadata: {})
    child = graph_a.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    assert_raises(ActiveRecord::InvalidForeignKey) do
      DAG::Edge.new(
        graph_id: graph_a.id,
        from_node_id: dirty_parent.id,
        to_node_id: child.id,
        edge_type: DAG::Edge::DEPENDENCY,
        metadata: {}
      ).save!(validate: false)
    end

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph_a, limit: 10, claimed_by: "test")
    assert_equal [child.id], claimed.map(&:id)
  end

  test "claim_executable_nodes skips locked rows" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    node_1 = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    node_2 = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    first, second = [node_1, node_2].sort_by(&:id)

    locked = Queue.new
    release = Queue.new

    locker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          DAG::Node.where(id: first.id).lock("FOR UPDATE").load
          locked << true
          release.pop
        end
      end
    end

    locked.pop

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 1, claimed_by: "test")
    assert_equal [second.id], claimed.map(&:id)
  ensure
    release << true
    locker.join
  end
end
