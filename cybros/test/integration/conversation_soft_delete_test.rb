require "test_helper"

class ConversationSoftDeleteTest < ActionDispatch::IntegrationTest
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

  test "soft delete hides a node from message_page and can be restored" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")
    lane = conversation.dag_graph.main_lane

    post conversation_messages_path(conversation), params: { content: "Hello" }
    node = conversation.reload.dag_graph.nodes.active.where(node_type: Messages::UserMessage.node_type_key).order(:id).last
    assert node

    before = lane.message_page(limit: 50, mode: :preview).fetch("message_ids")
    assert_includes before, node.id

    delete "/conversations/#{conversation.id}/nodes/#{node.id}"
    assert_response :redirect
    assert node.reload.deleted_at.present?

    after_ids = lane.message_page(limit: 50, mode: :preview).fetch("message_ids")
    assert_not_includes after_ids, node.id

    post "/conversations/#{conversation.id}/nodes/#{node.id}/restore"
    assert_response :redirect
    assert_nil node.reload.deleted_at
  end
end
