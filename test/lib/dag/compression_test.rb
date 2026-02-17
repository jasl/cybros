require "test_helper"

class DAG::CompressionTest < ActiveSupport::TestCase
  test "compress! marks nodes and edges compressed and rewires boundary edges through a summary node" do
    conversation = Conversation.create!

    a = conversation.dag_nodes.create!(node_type: DAG::Node::USER_MESSAGE, state: DAG::Node::FINISHED, content: "hi", metadata: {})
    b = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::FINISHED, content: "hello", metadata: {})
    c = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: { "name" => "task" })
    d = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

    edge_ab = conversation.dag_edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    edge_bc = conversation.dag_edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)
    edge_cd = conversation.dag_edges.create!(from_node_id: c.id, to_node_id: d.id, edge_type: DAG::Edge::SEQUENCE)

    summary = conversation.compress!(
      node_ids: [b.id, c.id],
      summary_content: "summary",
      summary_metadata: { "kind" => "test" }
    )

    assert_equal DAG::Node::SUMMARY, summary.node_type
    assert_equal DAG::Node::FINISHED, summary.state
    assert_equal "summary", summary.content

    [b.reload, c.reload].each do |node|
      assert node.compressed_at.present?
      assert_equal summary.id, node.compressed_by_id
    end

    [edge_ab.reload, edge_bc.reload, edge_cd.reload].each do |edge|
      assert edge.compressed_at.present?
    end

    assert conversation.dag_edges.active.exists?(
      from_node_id: a.id,
      to_node_id: summary.id,
      edge_type: DAG::Edge::SEQUENCE,
      metadata: edge_ab.metadata.merge("replaces_edge_id" => edge_ab.id)
    )
    assert conversation.dag_edges.active.exists?(
      from_node_id: summary.id,
      to_node_id: d.id,
      edge_type: DAG::Edge::SEQUENCE,
      metadata: edge_cd.metadata.merge("replaces_edge_id" => edge_cd.id)
    )
  end
end
