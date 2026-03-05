require "test_helper"

class ConversationNodeVisibilityTest < ActionDispatch::IntegrationTest
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

  test "exclude/include toggles a node's context visibility without removing it from transcript" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    node = conversation.reload.dag_graph.nodes.active.where(node_type: Messages::UserMessage.node_type_key).order(:id).last
    assert node

    post "/conversations/#{conversation.id}/nodes/#{node.id}/exclude"
    assert_response :redirect
    assert node.reload.context_excluded_at.present?

    post "/conversations/#{conversation.id}/nodes/#{node.id}/include"
    assert_response :redirect
    assert_nil node.reload.context_excluded_at
  end
end
