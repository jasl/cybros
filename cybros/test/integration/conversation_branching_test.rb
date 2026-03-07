require "test_helper"

class ConversationBranchingTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    email = "branching-#{SecureRandom.hex(4)}@example.com"
    identity =
      Identity.create!(
        email: email,
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: email, password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "branching from a node creates a child conversation and redirects to it" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")

    # Create a finished assistant node we can branch from.
    post conversation_messages_path(conversation), params: { content: "Hello" }
    agent = conversation.reload.dag_graph.leaf_nodes.order(:id).last
    agent.mark_running!
    agent.mark_finished!(content: "Hi")

    assert_difference -> { Conversation.count }, +1 do
      post "/conversations/#{conversation.id}/branch", params: { from_node_id: agent.id, title: "Branch" }
    end

    child = Conversation.order(:id).last
    assert_redirected_to conversation_path(child)
    assert_equal conversation.id, child.root_conversation_id
    assert_equal conversation.id, child.parent_conversation_id
    assert_equal agent.id, child.forked_from_node_id
    assert_equal "branch", child.kind

    page = child.message_page(limit: 20, mode: :full)

    assert_equal [Messages::AgentMessage.node_type_key], page.fetch("messages").map { |message| message.fetch("node_type") }
    assert_equal ["Hi"], page.fetch("messages").map { |message| message.dig("payload", "output", "content").to_s }
    assert_equal 0, ConversationRun.where(conversation_id: child.id).count
    assert_equal 0,
                 child.root_graph.nodes.active.where(
                   lane_id: child.chat_lane.id,
                   state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL],
                 ).count
  end

  test "branching from a user message is rejected" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    user_node =
      conversation.reload.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .last

    assert_no_difference -> { Conversation.count } do
      post "/conversations/#{conversation.id}/branch", params: { from_node_id: user_node.id, title: "Branch" }
    end

    assert_response :unprocessable_entity
  end
end
