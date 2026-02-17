require "test_helper"

class DAG::Visualization::MermaidExporterTest < ActiveSupport::TestCase
  test "exports branch edges with branch_kinds" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    root = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    forked = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    merged = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

    graph.edges.create!(
      from_node_id: root.id,
      to_node_id: forked.id,
      edge_type: DAG::Edge::BRANCH,
      metadata: { "branch_kinds" => ["fork"] }
    )
    graph.edges.create!(
      from_node_id: root.id,
      to_node_id: merged.id,
      edge_type: DAG::Edge::BRANCH,
      metadata: { "branch_kinds" => ["fork", "retry"] }
    )

    mermaid = conversation.to_mermaid

    assert_includes mermaid, "flowchart TD"
    assert_includes mermaid, "branch:fork"
    assert_includes mermaid, "branch:fork,retry"
  end
end
