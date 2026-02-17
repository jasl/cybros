require "test_helper"

class DAG::NodeTest < ActiveSupport::TestCase
  test "retry! creates a new pending node, copies incoming blocking edges, and adds a branch edge" do
    conversation = Conversation.create!

    parent = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    original = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    conversation.dag_edges.create!(from_node_id: parent.id, to_node_id: original.id, edge_type: DAG::Edge::DEPENDENCY)

    retried = original.retry!

    assert_equal DAG::Node::PENDING, retried.state
    assert_equal original.id, retried.retry_of_id
    assert_equal 2, retried.metadata["attempt"]

    assert conversation.dag_edges.active.exists?(
      from_node_id: parent.id,
      to_node_id: retried.id,
      edge_type: DAG::Edge::DEPENDENCY
    )

    branch_edge = conversation.dag_edges.active.find_by!(
      from_node_id: original.id,
      to_node_id: retried.id,
      edge_type: DAG::Edge::BRANCH
    )
    assert_equal "retry", branch_edge.metadata["branch_kind"]
  end

  test "mark_cancelled! works from pending" do
    conversation = Conversation.create!
    node = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    assert node.mark_cancelled!(reason: "no longer needed")
    assert_equal DAG::Node::CANCELLED, node.state
    assert_equal "no longer needed", node.metadata["reason"]
  end
end
