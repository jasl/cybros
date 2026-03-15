require "test_helper"

class Cybros::CLI::DAGMermaidExportTest < ActiveSupport::TestCase
  test "exports mermaid for a conversation" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "Hello" },
      metadata: {}
    )
    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "World" },
      metadata: {}
    )
    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    result = Cybros::CLI::DAGMermaidExport.call(conversation_id: conversation.id)

    assert_equal conversation.id, result.dig("conversation", "id")
    assert_equal graph.id, result.dig("graph", "id")
    assert_includes result.fetch("mermaid"), "flowchart TD"
    assert_includes result.fetch("mermaid"), "Hello"
    assert_includes result.fetch("mermaid"), "World"
    assert_equal 1, result.dig("analysis", "root_count")
    assert_equal 1, result.dig("analysis", "component_count")
  end

  test "reports disconnected roots in graph analysis" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    first = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    second = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    result = Cybros::CLI::DAGMermaidExport.call(conversation_id: conversation.id)

    assert_equal 2, result.dig("analysis", "node_count")
    assert_equal 0, result.dig("analysis", "edge_count")
    assert_equal 2, result.dig("analysis", "root_count")
    assert_equal 2, result.dig("analysis", "component_count")
    assert_equal [1, 1], result.dig("analysis", "component_sizes").sort
    assert_equal [first.id, second.id].sort, result.dig("analysis", "root_node_ids").sort
  end
end
