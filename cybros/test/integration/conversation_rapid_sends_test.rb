require "test_helper"

class ConversationRapidSendsTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "rapid sends preserve user order and pair each user with an agent placeholder by turn" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")

    messages = ["m1", "m2", "m3", "m4", "m5"]
    messages.each do |text|
      post conversation_messages_path(conversation),
           params: { content: text },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
    end

    lane = conversation.reload.dag_graph.main_lane
    page = lane.message_page(limit: 20, mode: :full)
    transcript = page.fetch("messages")

    # Expect alternating user/agent placeholders for each send.
    assert_equal messages.length * 2, transcript.length

    messages.each_with_index do |text, i|
      user_msg = transcript[i * 2]
      agent_msg = transcript[i * 2 + 1]

      assert_equal Messages::UserMessage.node_type_key, user_msg.fetch("node_type")
      assert_equal text, user_msg.dig("payload", "input", "content").to_s

      assert_equal Messages::AgentMessage.node_type_key, agent_msg.fetch("node_type")
      assert_equal user_msg.fetch("turn_id").to_s, agent_msg.fetch("turn_id").to_s
    end
  end
end
