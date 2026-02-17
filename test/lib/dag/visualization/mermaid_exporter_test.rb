require "test_helper"

class DAG::Visualization::MermaidExporterTest < ActiveSupport::TestCase
  test "to_mermaid exports nodes and edges" do
    conversation = Conversation.create!

    a = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: { "name" => "a" })
    b = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: { "name" => "b" })
    conversation.dag_edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)

    output = conversation.to_mermaid

    assert_includes output, "flowchart TD"
    assert_includes output, "N_#{a.id.delete("-")}"
    assert_includes output, "N_#{b.id.delete("-")}"
    assert_includes output, "|sequence|"
  end

  test "to_mermaid labels retry branch edges" do
    conversation = Conversation.create!

    original = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    retried = original.retry!

    output = conversation.to_mermaid

    assert_includes output, "N_#{original.id.delete("-")}"
    assert_includes output, "N_#{retried.id.delete("-")}"
    assert_includes output, "branch:retry"
  end
end
