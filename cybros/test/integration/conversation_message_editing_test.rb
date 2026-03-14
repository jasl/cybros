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

  test "posting with edit_node_id rejects attachment-bearing user turns and preserves the manifest" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    original =
      conversation.append_user_message!(
        content: "",
        attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
      )
    user_node = original.fetch(:user_node)
    original_agent = original.fetch(:agent_node)
    original_agent.mark_running!
    original_agent.mark_finished!(content: "Attachment received")

    assert_no_difference -> { ConversationRun.count } do
      post conversation_messages_path(conversation),
           params: {
             content: "Edited text",
             edit_node_id: user_node.id,
           },
           as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Editing attachments is not supported yet."
    assert_equal ["attachment-note.txt"], user_node.reload.body_input.fetch("attachments").map { |entry| entry.fetch("filename") }
    assert_equal 1, conversation.conversation_attachments.where(source_message_node_id: user_node.id).count
  end

  private

    def uploaded_fixture(name, content_type)
      Rack::Test::UploadedFile.new(fixture_path(name), content_type)
    end

    def fixture_path(name)
      Rails.root.join("test/fixtures/files/#{name}")
    end
end
