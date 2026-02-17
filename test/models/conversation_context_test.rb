require "test_helper"

class ConversationContextTest < ActiveSupport::TestCase
  test "context_for returns preview payload by default and context_for_full includes full output" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert_equal 2000, Messages::AgentMessage.new.preview_max_chars
    long_content = "a" * (Messages::AgentMessage.new.preview_max_chars + 50)
    agent = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      body_output: { "content" => long_content },
      metadata: {}
    )

    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    preview = conversation.context_for(agent.id)
    agent_preview = preview.find { |node| node.fetch("node_id") == agent.id }

    assert_equal({ "content" => "hi" }, preview.find { |node| node.fetch("node_id") == user.id }.dig("payload", "input"))
    assert agent_preview.dig("payload", "output_preview", "content").length <= Messages::AgentMessage.new.preview_max_chars
    assert_not agent_preview.fetch("payload").key?("output")

    full = conversation.context_for_full(agent.id)
    agent_full = full.find { |node| node.fetch("node_id") == agent.id }

    assert_equal long_content, agent_full.dig("payload", "output", "content")
  end
end
