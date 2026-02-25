require "test_helper"

class DAG::EdgeTest < ActiveSupport::TestCase
  test "rejects edges that would introduce a cycle" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    b = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    c = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::SEQUENCE)

    edge = graph.edges.build(from_node_id: c.id, to_node_id: a.id, edge_type: DAG::Edge::SEQUENCE)
    assert_not edge.valid?
    assert_includes edge.errors.full_messages.join("\n"), "cycle"
  end

  test "rejects active edges that point to inactive nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    from_node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    to_node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    to_node.update!(compressed_at: Time.current, compressed_by_id: to_node.id)

    edge = graph.edges.build(from_node_id: from_node.id, to_node_id: to_node.id, edge_type: DAG::Edge::SEQUENCE)
    assert_not edge.valid?
    assert_includes edge.errors.full_messages.join("\n"), "active node"
  end

  test "cycle detection ignores paths through inactive nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    b = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    c = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::SEQUENCE)

    b.update!(compressed_at: Time.current, compressed_by_id: b.id)

    edge = graph.edges.build(from_node_id: c.id, to_node_id: a.id, edge_type: DAG::Edge::SEQUENCE)
    assert edge.valid?
  end
end
