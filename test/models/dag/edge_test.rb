require "test_helper"

class DAG::EdgeTest < ActiveSupport::TestCase
  test "rejects edges that would introduce a cycle" do
    conversation = Conversation.create!

    a = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    b = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    c = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})

    conversation.dag_edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    conversation.dag_edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::SEQUENCE)

    edge = conversation.dag_edges.build(from_node_id: c.id, to_node_id: a.id, edge_type: DAG::Edge::SEQUENCE)
    assert_not edge.valid?
    assert_includes edge.errors.full_messages.join("\n"), "cycle"
  end
end
