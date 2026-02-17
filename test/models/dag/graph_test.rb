require "test_helper"

class DAG::GraphTest < ActiveSupport::TestCase
  test "destroy purges nodes, edges, and payloads for the graph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: DAG::Node::USER_MESSAGE, state: DAG::Node::FINISHED, payload_input: { "content" => "hi" }, metadata: {})
    b = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::FINISHED, payload_output: { "content" => "hello" }, metadata: {})
    edge = graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)

    payload_ids = [a.payload_id, b.payload_id]
    graph_id = graph.id

    assert DAG::Node.where(graph_id: graph_id).exists?
    assert DAG::Edge.where(graph_id: graph_id).exists?
    assert DAG::NodePayload.where(id: payload_ids).count == payload_ids.length

    graph.destroy!

    assert_not DAG::Graph.exists?(graph_id)
    assert_not DAG::Node.where(graph_id: graph_id).exists?
    assert_not DAG::Edge.where(graph_id: graph_id).exists?
    assert_equal 0, DAG::NodePayload.where(id: payload_ids).count
    assert_not DAG::Edge.exists?(edge.id)
  end
end
