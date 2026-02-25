require "test_helper"

class DAG::Visualization::MermaidExporterTest < ActiveSupport::TestCase
  test "exports system and developer message snippets from input content" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    system = graph.nodes.create!(
      node_type: Messages::SystemMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "system: be helpful" },
      metadata: {}
    )
    developer = graph.nodes.create!(
      node_type: Messages::DeveloperMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "developer: answer in Chinese" },
      metadata: {}
    )

    graph.edges.create!(from_node_id: system.id, to_node_id: developer.id, edge_type: DAG::Edge::SEQUENCE)

    mermaid = graph.to_mermaid

    assert_includes mermaid, "system: be helpful"
    assert_includes mermaid, "developer: answer in Chinese"
  end

  test "exports branch edges with branch_kinds" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    root = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    forked = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    merged = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

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

    mermaid = graph.to_mermaid

    assert_includes mermaid, "flowchart TD"
    assert_includes mermaid, "branch:fork"
    assert_includes mermaid, "branch:fork,retry"
  end
end
