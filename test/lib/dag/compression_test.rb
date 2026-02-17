require "test_helper"

class DAG::CompressionTest < ActiveSupport::TestCase
  test "compress! marks nodes and edges compressed and rewires boundary edges through a summary node" do
    conversation = Conversation.create!

    a = conversation.dag_nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      runnable: DAG::Runnables::Text.new(content: "hi"),
      metadata: {}
    )
    b = conversation.dag_nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      runnable: DAG::Runnables::Text.new(content: "hello"),
      metadata: {}
    )
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
    assert_equal "summary", summary.runnable.content

    [b.reload, c.reload].each do |node|
      assert node.compressed_at.present?
      assert_equal summary.id, node.compressed_by_id
    end

    [edge_ab.reload, edge_bc.reload, edge_cd.reload].each do |edge|
      assert edge.compressed_at.present?
    end

    rewired_incoming = conversation.dag_edges.active.find_by!(
      from_node_id: a.id,
      to_node_id: summary.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert_equal [edge_ab.id], rewired_incoming.metadata.fetch("replaces_edge_ids")

    rewired_outgoing = conversation.dag_edges.active.find_by!(
      from_node_id: summary.id,
      to_node_id: d.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert_equal [edge_cd.id], rewired_outgoing.metadata.fetch("replaces_edge_ids")
  end

  test "compress! deduplicates boundary edges that would collapse into duplicates" do
    conversation = Conversation.create!

    outside_parent = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: { "name" => "outside_parent" })
    inside_a = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: { "name" => "inside_a" })
    inside_b = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: { "name" => "inside_b" })
    outside_child = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

    in_1 = conversation.dag_edges.create!(from_node_id: outside_parent.id, to_node_id: inside_a.id, edge_type: DAG::Edge::DEPENDENCY)
    in_2 = conversation.dag_edges.create!(from_node_id: outside_parent.id, to_node_id: inside_b.id, edge_type: DAG::Edge::DEPENDENCY)
    out_1 = conversation.dag_edges.create!(from_node_id: inside_a.id, to_node_id: outside_child.id, edge_type: DAG::Edge::SEQUENCE)
    out_2 = conversation.dag_edges.create!(from_node_id: inside_b.id, to_node_id: outside_child.id, edge_type: DAG::Edge::SEQUENCE)

    summary = conversation.compress!(node_ids: [inside_a.id, inside_b.id], summary_content: "summary")

    assert_equal 1, conversation.dag_edges.active.where(
      from_node_id: outside_parent.id,
      to_node_id: summary.id,
      edge_type: DAG::Edge::DEPENDENCY
    ).count
    incoming = conversation.dag_edges.active.find_by!(
      from_node_id: outside_parent.id,
      to_node_id: summary.id,
      edge_type: DAG::Edge::DEPENDENCY
    )
    assert_equal [in_1.id, in_2.id].sort, incoming.metadata.fetch("replaces_edge_ids").sort

    assert_equal 1, conversation.dag_edges.active.where(
      from_node_id: summary.id,
      to_node_id: outside_child.id,
      edge_type: DAG::Edge::SEQUENCE
    ).count
    outgoing = conversation.dag_edges.active.find_by!(
      from_node_id: summary.id,
      to_node_id: outside_child.id,
      edge_type: DAG::Edge::SEQUENCE
    )
    assert_equal [out_1.id, out_2.id].sort, outgoing.metadata.fetch("replaces_edge_ids").sort
  end
end
