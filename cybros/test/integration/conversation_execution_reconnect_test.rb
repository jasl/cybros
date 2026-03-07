require "test_helper"

class ConversationExecutionReconnectTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "show reconstructs current execution progress without prior cable history" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
    agent = turn.fetch(:agent_node)
    agent.mark_running!
    agent.body.merge_output!("content" => "Partial answer")
    agent.body.save!

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
      diagnostic_level: "debug",
    )

    get conversation_path(conversation)

    assert_response :success
    assert_includes response.body, "memory_search"
    assert_includes response.body, "Partial answer"
    assert_includes response.body, %(data-run-state=)
  end

  test "refresh for the current turn ignores stale previous-turn execution state" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.root_graph

    first_turn = conversation.append_user_message!(content: "First", diagnostic_level: "debug")
    first_agent = first_turn.fetch(:agent_node)
    first_agent.mark_running!

    stale_task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        turn_id: first_agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "memory_search",
          "requested_name" => "memory_search",
          "tool_call_id" => "tc_stale",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )
    DAG::NodeEventStream.new(node: stale_task).activity_started!(
      activity_id: "task:#{stale_task.id}",
      activity_kind: "tool_call",
      phase: "execution",
      diagnostic_level: "debug",
    )
    first_agent.mark_stopped!(reason: "steered")

    second_turn = conversation.append_user_message!(content: "Second", diagnostic_level: "debug")
    current_agent = second_turn.fetch(:agent_node)
    current_agent.mark_running!

    current_task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::AWAITING_APPROVAL,
        lane_id: conversation.chat_lane.id,
        turn_id: current_agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "write_file",
          "requested_name" => "write_file",
          "tool_call_id" => "tc_current",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )
    DAG::NodeEventStream.new(node: current_task).activity_waiting!(
      activity_id: "task:#{current_task.id}",
      activity_kind: "tool_call",
      phase: "authorization",
      diagnostic_level: "debug",
      data: { "reason" => "approval_required" },
    )

    get refresh_conversation_messages_path(conversation),
        params: { node_id: current_agent.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, "write_file"
    refute_includes response.body, "memory_search"
    assert_includes response.body, %(data-run-state=)
  end
end
