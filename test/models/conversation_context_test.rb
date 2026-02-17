require "test_helper"

class ConversationContextTest < ActiveSupport::TestCase
  test "context_for returns preview payload by default and context_for_full includes full output" do
    conversation = Conversation.create!

    user = conversation.dag_nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_input: { "content" => "hi" },
      metadata: {}
    )

    long_content = "a" * (DAG::NodePayload::PREVIEW_MAX_CHARS + 50)
    agent = conversation.dag_nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_output: { "content" => long_content },
      metadata: {}
    )

    conversation.dag_edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    preview = conversation.context_for(agent.id)
    agent_preview = preview.find { |node| node.fetch("node_id") == agent.id }

    assert_equal({ "content" => "hi" }, preview.find { |node| node.fetch("node_id") == user.id }.dig("payload", "input"))
    assert agent_preview.dig("payload", "output_preview", "content").length <= DAG::NodePayload::PREVIEW_MAX_CHARS
    assert_not agent_preview.fetch("payload").key?("output")

    full = conversation.context_for_full(agent.id)
    agent_full = full.find { |node| node.fetch("node_id") == agent.id }

    assert_equal long_content, agent_full.dig("payload", "output", "content")
  end
end
