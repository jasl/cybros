require "test_helper"

class ConversationExecutionProgressUiTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "running assistant bubble renders a structured execution block with multiple activities and partial text" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
    agent = turn.fetch(:agent_node)
    agent.mark_running!
    agent.body.merge_output!("content" => "Partial answer")
    agent.body.save!

    first_task =
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
    second_task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::AWAITING_APPROVAL,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "write_file",
          "requested_name" => "write_file",
          "tool_call_id" => "tc_2",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )

    DAG::NodeEventStream.new(node: first_task).activity_started!(
      activity_id: "task:#{first_task.id}",
      activity_kind: "tool_call",
      phase: "execution",
      diagnostic_level: "debug",
      data: { "executor" => "task_executor" },
    )
    DAG::NodeEventStream.new(node: second_task).activity_waiting!(
      activity_id: "task:#{second_task.id}",
      activity_kind: "tool_call",
      phase: "authorization",
      diagnostic_level: "debug",
      data: { "reason" => "approval_required" },
    )

    get conversation_path(conversation)

    assert_response :success
    assert_select '[data-role="run-state"]', count: 1
    assert_select '[data-role="run-state-summary"]', count: 1
    assert_select '[data-role="run-state-activity"]', count: 2
    assert_includes response.body, %(data-role="run-state")
    assert_includes response.body, %(data-role="run-state-summary")
    assert_includes response.body, %(data-role="run-state-activity")
    assert_includes response.body, "memory_search"
    assert_includes response.body, "write_file"
    assert_includes response.body, "Running"
    assert_includes response.body, "Partial answer"
  end

  test "running assistant bubble shows a bounded hidden failure summary for composer-only activity failures" do
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
        state: DAG::Node::FINISHED,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "compact_context",
          "requested_name" => "compact_context",
          "tool_call_id" => "tc_hidden",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )

    DAG::NodeEventStream.new(node: task).activity_planned!(
      activity_id: "task:#{task.id}",
      activity_kind: "preflight_task",
      phase: "preflight",
      diagnostic_level: "debug",
    )
    DAG::NodeEventStream.new(node: task).activity_failed!(
      activity_id: "task:#{task.id}",
      activity_kind: "preflight_task",
      phase: "preflight",
      diagnostic_level: "debug",
      data: { "error" => "Compaction failed" },
    )

    get conversation_path(conversation)

    assert_response :success
    assert_select '[data-role="run-state"]', count: 1
    assert_select '[data-role="run-state-hidden-summary"]', count: 1
    assert_select '[data-role="run-state-activity"]', count: 0
    assert_includes response.body, "1 hidden failure"
    assert_includes response.body, "Partial answer"
  end

  test "terminal assistant bubble collapses back to ordinary final output" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    turn = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
    agent = turn.fetch(:agent_node)
    agent.mark_running!
    agent.mark_finished!(content: "# Done")

    get conversation_path(conversation)

    assert_response :success
    assert_includes response.body, %(data-controller="markdown")
    assert_includes response.body, "# Done"
    refute_includes response.body, %(data-role="run-state")
  end
end
