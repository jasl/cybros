require "test_helper"

class ConversationQueueItemsTest < ActionDispatch::IntegrationTest
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

  test "edit queued item removes the selected queued turn and preserves the others" do
    user = sign_in_owner!
    conversation = queued_conversation_for(user: user)
    queued = queue_user_nodes(conversation)

    post edit_conversation_queue_item_path(conversation, queued.fetch(1)), as: :json
    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal true, payload.fetch("ok")
    assert_includes payload.fetch("turbo_stream"), ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    assert_includes payload.fetch("turbo_stream"), ActionView::RecordIdentifier.dom_id(conversation, :composer_status_rail)

    assert_equal %w[queued\ one queued\ three], queued_contents(conversation)
    refute_includes visible_message_texts(conversation), "queued two"
  end

  test "steer queued item applies the selected content to the current turn and preserves the other queued turns" do
    user = sign_in_owner!
    conversation = queued_conversation_for(user: user)
    queued = queue_user_nodes(conversation)

    post steer_conversation_queue_item_path(conversation, queued.fetch(1)), as: :json
    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal true, payload.fetch("ok")

    active_user =
      conversation.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, turn_id: queue_running_turn_id(conversation), node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .last

    assert_equal "queued two", active_user.body_input.fetch("content")
    assert_equal %w[queued\ one queued\ three], queued_contents(conversation)
  end

  test "cancel queued item removes only the selected queued turn" do
    user = sign_in_owner!
    conversation = queued_conversation_for(user: user)
    queued = queue_user_nodes(conversation)

    delete conversation_queue_item_path(conversation, queued.fetch(0)), as: :json
    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal true, payload.fetch("ok")

    assert_equal %w[queued\ two queued\ three], queued_contents(conversation)
    refute_includes visible_message_texts(conversation), "queued one"
  end

  private

    def queued_conversation_for(user:)
      conversation =
        create_conversation!(
          user: user,
          title: "Queued",
          metadata: {
            "agent" => { "agent_profile" => "coding" },
            "input_policy" => {
              "running_input_policy" => "queue",
              "input_coalescing" => { "enabled" => false },
            },
          },
        )

      first = conversation.append_user_message!(content: "original request")
      first_agent = first.fetch(:agent_node)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test")
      assert_equal [first_agent.id], claimed.map(&:id)

      %w[queued\ one queued\ two queued\ three].each do |content|
        conversation.append_user_message!(content: content)
      end

      conversation
    end

    def queue_user_nodes(conversation)
      queue_items = conversation.composer_state.dig("queue", "items")
      queue_items.map { |item| item.fetch("user_node_id") }
    end

    def queued_contents(conversation)
      conversation.composer_state.dig("queue", "items").map { |item| item.fetch("content") }
    end

    def visible_message_texts(conversation)
      conversation.message_page(limit: 20, mode: :full).fetch("messages").filter_map do |message|
        message.dig("payload", "input", "content").to_s.presence ||
          message.dig("payload", "output_preview", "content").to_s.presence
      end
    end

    def queue_running_turn_id(conversation)
      conversation.composer_state.fetch("running_turn_id")
    end
end
