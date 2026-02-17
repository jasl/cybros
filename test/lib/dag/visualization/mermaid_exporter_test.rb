require "test_helper"

class DAG::Visualization::MermaidExporterTest < ActiveSupport::TestCase
  test "exports branch edges with branch_kinds" do
    conversation = Conversation.create!

    root = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    forked = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    merged = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

    conversation.dag_edges.create!(
      from_node_id: root.id,
      to_node_id: forked.id,
      edge_type: DAG::Edge::BRANCH,
      metadata: { "branch_kinds" => ["fork"] }
    )
    conversation.dag_edges.create!(
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
