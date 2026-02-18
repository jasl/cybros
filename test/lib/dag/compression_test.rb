require "test_helper"

class DAG::CompressionTest < ActiveSupport::TestCase
  test "compress! marks nodes and edges compressed and rewires boundary edges through a summary node" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    b = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )
    c = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: { "name" => "task" })
    d = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

    edge_ab = graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    edge_bc = graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)
    edge_cd = graph.edges.create!(from_node_id: c.id, to_node_id: d.id, edge_type: DAG::Edge::SEQUENCE)

    summary = conversation.compress!(
      node_ids: [b.id, c.id],
      summary_content: "summary",
      summary_metadata: { "kind" => "test" }
    )

    assert_equal Messages::Summary.node_type_key, summary.node_type
    assert_equal DAG::Node::FINISHED, summary.state
    assert_equal "summary", summary.body_output["content"]
    assert_equal b.lane_id, summary.lane_id

    [b.reload, c.reload].each do |node|
      assert node.compressed_at.present?
      assert_equal summary.id, node.compressed_by_id
    end

    [edge_ab.reload, edge_bc.reload, edge_cd.reload].each do |edge|
      assert edge.compressed_at.present?
    end

    rewired_incoming = graph.edges.active.find_by!(
      from_node_id: a.id,
      to_node_id: summary.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert_equal [edge_ab.id], rewired_incoming.metadata.fetch("replaces_edge_ids")

    rewired_outgoing = graph.edges.active.find_by!(
      from_node_id: summary.id,
      to_node_id: d.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert_equal [edge_cd.id], rewired_outgoing.metadata.fetch("replaces_edge_ids")
  end

  test "compress! deduplicates boundary edges that would collapse into duplicates" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    outside_parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: { "name" => "outside_parent" })
    inside_a = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: { "name" => "inside_a" })
    inside_b = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: { "name" => "inside_b" })
    outside_child = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

    in_1 = graph.edges.create!(from_node_id: outside_parent.id, to_node_id: inside_a.id, edge_type: DAG::Edge::DEPENDENCY)
    in_2 = graph.edges.create!(from_node_id: outside_parent.id, to_node_id: inside_b.id, edge_type: DAG::Edge::DEPENDENCY)
    out_1 = graph.edges.create!(from_node_id: inside_a.id, to_node_id: outside_child.id, edge_type: DAG::Edge::SEQUENCE)
    out_2 = graph.edges.create!(from_node_id: inside_b.id, to_node_id: outside_child.id, edge_type: DAG::Edge::SEQUENCE)

    summary = conversation.compress!(node_ids: [inside_a.id, inside_b.id], summary_content: "summary")
    assert_equal inside_a.lane_id, summary.lane_id

    assert_equal 1, graph.edges.active.where(
      from_node_id: outside_parent.id,
      to_node_id: summary.id,
      edge_type: DAG::Edge::DEPENDENCY
    ).count
    incoming = graph.edges.active.find_by!(
      from_node_id: outside_parent.id,
      to_node_id: summary.id,
      edge_type: DAG::Edge::DEPENDENCY
    )
    assert_equal [in_1.id, in_2.id].sort, incoming.metadata.fetch("replaces_edge_ids").sort

    assert_equal 1, graph.edges.active.where(
      from_node_id: summary.id,
      to_node_id: outside_child.id,
      edge_type: DAG::Edge::SEQUENCE
    ).count
    outgoing = graph.edges.active.find_by!(
      from_node_id: summary.id,
      to_node_id: outside_child.id,
      edge_type: DAG::Edge::SEQUENCE
    )
    assert_equal [out_1.id, out_2.id].sort, outgoing.metadata.fetch("replaces_edge_ids").sort
  end

  test "compress! rejects compressing nodes across multiple lanes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    main = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: graph.main_lane.id, metadata: {})
    branch = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, lane_id: lane.id, metadata: {})
    outside = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

    graph.edges.create!(from_node_id: main.id, to_node_id: outside.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: branch.id, to_node_id: outside.id, edge_type: DAG::Edge::SEQUENCE)

    error =
      assert_raises(ArgumentError) do
        conversation.compress!(node_ids: [main.id, branch.id], summary_content: "summary")
      end
    assert_match(/multiple lanes/, error.message)
  end
end
