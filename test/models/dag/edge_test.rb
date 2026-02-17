require "test_helper"

class DAG::EdgeTest < ActiveSupport::TestCase
  test "rejects edges that would introduce a cycle" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    b = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    c = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})

    graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::SEQUENCE)

    edge = graph.edges.build(from_node_id: c.id, to_node_id: a.id, edge_type: DAG::Edge::SEQUENCE)
    assert_not edge.valid?
    assert_includes edge.errors.full_messages.join("\n"), "cycle"
  end
end
