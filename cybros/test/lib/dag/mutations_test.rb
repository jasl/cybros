require "test_helper"

class DAG::MutationsTest < ActiveSupport::TestCase
  test "create_node(content:) writes content to the NodeBody created_content_destination" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000250"

    system = nil
    developer = nil
    user = nil
    task = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      system = m.create_node(node_type: Messages::SystemMessage.node_type_key, state: DAG::Node::FINISHED, content: "sys", metadata: {})
      developer = m.create_node(node_type: Messages::DeveloperMessage.node_type_key, state: DAG::Node::FINISHED, content: "dev", metadata: {})
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "u", metadata: {})
      task = m.create_node(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, content: "r", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, content: "a", metadata: {})

      m.create_edge(from_node: system, to_node: developer, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: developer, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: task, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_equal({ "content" => "sys" }, system.body_input)
    assert_equal({ "content" => "dev" }, developer.body_input)
    assert_equal({ "content" => "u" }, user.body_input)
    assert_equal({ "result" => "r" }, task.body_output)
    assert_equal({ "content" => "a" }, agent.body_output)

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end
end
