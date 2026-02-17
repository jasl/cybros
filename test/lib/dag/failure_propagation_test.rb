require "test_helper"

class DAG::FailurePropagationTest < ActiveSupport::TestCase
  test "propagate! skips nodes blocked by failed dependencies and cascades" do
    conversation = Conversation.create!

    a = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    b = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    c = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

    e1 = conversation.dag_edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::DEPENDENCY)
    e2 = conversation.dag_edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)

    DAG::FailurePropagation.propagate!(conversation_id: conversation.id)

    assert_equal DAG::Node::SKIPPED, b.reload.state
    assert_equal "blocked_by_failed_dependencies", b.metadata["reason"]
    blocked_by_b = b.metadata.fetch("blocked_by")
    assert_equal 1, blocked_by_b.length
    assert_equal a.id, blocked_by_b.first.fetch("node_id")
    assert_equal DAG::Node::ERRORED, blocked_by_b.first.fetch("state")
    assert_equal e1.id, blocked_by_b.first.fetch("edge_id")

    assert_equal DAG::Node::SKIPPED, c.reload.state
    assert_equal "blocked_by_failed_dependencies", c.metadata["reason"]
    blocked_by_c = c.metadata.fetch("blocked_by")
    assert_equal 1, blocked_by_c.length
    assert_equal b.id, blocked_by_c.first.fetch("node_id")
    assert_equal DAG::Node::SKIPPED, blocked_by_c.first.fetch("state")
    assert_equal e2.id, blocked_by_c.first.fetch("edge_id")
  end

  test "propagate! does not skip nodes whose dependency parents are pending" do
    conversation = Conversation.create!

    parent = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    child = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    conversation.dag_edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    DAG::FailurePropagation.propagate!(conversation_id: conversation.id)

    assert_equal DAG::Node::PENDING, child.reload.state
  end
end
