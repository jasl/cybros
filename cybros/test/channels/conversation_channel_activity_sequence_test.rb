require "test_helper"

class ConversationChannelActivitySequenceTest < ActionCable::Channel::TestCase
  tests ConversationChannel

  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)
    stub_connection current_identity_id: identity.id
    user
  end

  test "broadcasted activity events include ordering and correlation fields" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    turn = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
    task =
      conversation.root_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        turn_id: turn.fetch(:agent_node).turn_id,
        metadata: {},
        body_input: {
          "name" => "memory_search",
          "requested_name" => "memory_search",
          "tool_call_id" => "tc_1",
        },
      )

    subscribe conversation_id: conversation.id
    assert subscription.confirmed?

    broadcasting = ConversationChannel.broadcasting_for(conversation)
    stream = DAG::NodeEventStream.new(node: task)

    assert_broadcasts(broadcasting, 1) do
      stream.activity_started!(
        activity_id: "task:#{task.id}",
        activity_kind: "tool_call",
        phase: "execution",
        diagnostic_level: "debug",
      )
    end

    payload = JSON.parse(broadcasts(broadcasting).last)

    assert_equal "node_event", payload.fetch("type")
    assert_equal conversation.id.to_s, payload.fetch("conversation_id")
    assert_equal task.turn_id.to_s, payload.fetch("turn_id")
    assert_equal task.id.to_s, payload.fetch("node_id")
    assert_equal DAG::NodeEvent::ACTIVITY_STARTED, payload.fetch("kind")
    assert_equal 1, payload.fetch("sequence")
    assert_equal "task:#{task.id}", payload.fetch("activity_id")
    assert_equal "tool_call", payload.fetch("activity_kind")
    assert_equal "running", payload.fetch("activity_status")
    assert_equal "execution", payload.fetch("activity_phase")
    assert_equal task.id.to_s, payload.fetch("source_node_id")
    assert_equal "debug", payload.fetch("diagnostic_level")
  end
end
