require "test_helper"

class ConversationChannelExecutionReplayTest < ActionCable::Channel::TestCase
  tests ConversationChannel

  def sign_in_owner!
    identity =
      Identity.create!(
        email: "owner-#{SecureRandom.hex(4)}@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )
    user = User.create!(identity: identity, role: :owner)
    stub_connection current_identity_id: identity.id
    user
  end

  test "subscribing with a cursor replays missed task activity events for the selected assistant turn" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    first = DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "Partial", payload: {})

    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "memory_search",
          "requested_name" => "memory_search",
          "tool_call_id" => "tc_1",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )

    DAG::NodeEventStream.new(node: task).activity_started!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
    )

    transmissions.clear
    subscribe conversation_id: conversation.id, node_id: agent.id, cursor: first.id
    assert subscription.confirmed?

    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 1, events.length
    assert_equal DAG::NodeEvent::ACTIVITY_STARTED, events.last.fetch("kind")
    assert_equal task.id.to_s, events.last.fetch("node_id")
    assert_equal agent.turn_id.to_s, events.last.fetch("turn_id")
    assert_equal "task:#{task.id}", events.last.fetch("activity_id")
    assert_equal "tool_call", events.last.fetch("activity_kind")
    assert_equal "running", events.last.fetch("activity_status")
    assert_equal 1, events.last.fetch("sequence")
  end

  test "subscribing without a cursor uses the projected run_state event cursor to avoid replaying already-rendered activity events" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "memory_search",
          "requested_name" => "memory_search",
          "tool_call_id" => "tc_1",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )

    DAG::NodeEventStream.new(node: task).activity_started!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
    )

    transmissions.clear
    subscribe conversation_id: conversation.id, node_id: agent.id
    assert subscription.confirmed?

    assert transmissions.empty?, "expected no replay when the current run_state already reflects the latest event cursor"
  end

  test "poll_fallback replays activity events missed after partial delivery" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    first = DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "A", payload: {})

    subscribe conversation_id: conversation.id, node_id: agent.id, cursor: first.id
    assert subscription.confirmed?

    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::AWAITING_APPROVAL,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "write_file",
          "requested_name" => "write_file",
          "tool_call_id" => "tc_wait",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )

    transmissions.clear
    DAG::NodeEventStream.new(node: task).activity_waiting!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "authorization",
      data: { "reason" => "approval_required" },
    )

    perform :poll_fallback

    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 1, events.length
    assert_equal DAG::NodeEvent::ACTIVITY_WAITING, events.last.fetch("kind")
    assert_equal "awaiting_approval", events.last.fetch("activity_status")
    assert_equal "authorization", events.last.fetch("activity_phase")
    assert_equal task.id.to_s, events.last.fetch("node_id")
  end
end
