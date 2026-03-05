require "test_helper"

class ConversationBranchingTest < ActionDispatch::IntegrationTest
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
  end
end
