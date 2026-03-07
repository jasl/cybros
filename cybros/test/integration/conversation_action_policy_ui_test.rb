require "test_helper"

class ConversationActionPolicyUiTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "show renders action policy data for projected messages" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    agent = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    get conversation_path(conversation)
    assert_response :success

    assert_includes response.body, "data-message-actions-action-policy-value="
    assert_includes response.body, "&quot;regenerate&quot;:{&quot;supported&quot;:true,&quot;available&quot;:true,&quot;mode&quot;:&quot;in_place&quot;}"
  end

  test "show renders message-level retry button for errored agent messages" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          lane_id: conversation.chat_lane.id,
          metadata: { "error" => "boom" },
        )
      m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    get conversation_path(conversation)
    assert_response :success

    assert_includes response.body, "data-message-actions-target=\"retryButton\""
    assert_not_includes response.body, "data-message-actions-target=\"regenerateButton\""
  end
end
