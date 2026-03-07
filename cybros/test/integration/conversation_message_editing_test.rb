require "test_helper"
require "nokogiri"

class ConversationMessageEditingTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    email = "edit-#{SecureRandom.hex(4)}@example.com"
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

  test "posting with edit_node_id rewrites the latest user turn and queues a regenerated assistant" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    conversation.reload

    user_node =
      conversation.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .last
    original_agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    original_agent.mark_running!
    original_agent.mark_finished!(content: "Hi")

    assert_difference -> { ConversationRun.count }, +1 do
      post conversation_messages_path(conversation),
           params: {
             content: "Hello again",
             edit_node_id: user_node.id,
           },
           as: :turbo_stream
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type

    active_user =
      conversation.reload.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, turn_id: user_node.turn_id, node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .last

    assert_equal "Hello again", active_user.body_input.fetch("content")
    assert original_agent.reload.compressed_at.present?
    assert_includes response.body, "Hello again"

    user_wrapper = Nokogiri::HTML5.fragment(response.body).at_css(%([id="message_#{active_user.id}"]))
    refute_nil user_wrapper
    refute_includes user_wrapper.to_html, 'data-message-actions-target="branchButton"'
  end
end
