require "test_helper"

class ConversationRapidSendsTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "rapid sends keep queued turns out of the transcript and preserve their order in the composer queue" do
    user = create_user!
    sign_in!(user)

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "queue",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    messages = ["m1", "m2", "m3", "m4", "m5"]
    post conversation_messages_path(conversation),
         params: { content: messages.first },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success

    first_agent =
      conversation.reload.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test")
    assert_equal [first_agent.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, first_agent.reload.state

    messages.drop(1).each do |text|
      post conversation_messages_path(conversation),
           params: { content: text },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
    end

    page = conversation.reload.message_page(limit: 20, mode: :full)
    transcript = page.fetch("messages")
    composer_queue = conversation.composer_state.dig("queue", "items")

    assert_equal 2, transcript.length
    assert_equal Messages::UserMessage.node_type_key, transcript.first.fetch("node_type")
    assert_equal messages.first, transcript.first.dig("payload", "input", "content").to_s

    agent_msg = transcript.second
    assert_equal Messages::AgentMessage.node_type_key, agent_msg.fetch("node_type")
    assert_equal transcript.first.fetch("turn_id").to_s, agent_msg.fetch("turn_id").to_s
    assert_equal DAG::Node::RUNNING, agent_msg.fetch("state")

    assert_equal messages.drop(1), composer_queue.map { |item| item.fetch("content") }
  end
end
