require "test_helper"
require "nokogiri"

class ConversationMessagesRefreshExecutionTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "refresh rebuilds the same run_state from durable turn execution truth" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
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

    stream = DAG::NodeEventStream.new(node: task)
    stream.activity_started!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
      diagnostic_level: "debug",
      data: { "executor" => "task_executor" },
    )

    get refresh_conversation_messages_path(conversation),
        params: { node_id: agent.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.media_type, "text/vnd.turbo-stream.html"
    assert_includes response.body, %(target="message_#{agent.id}")
    assert_includes response.body, %(data-run-state=)

    fragment = Nokogiri::HTML.fragment(response.body)
    bubble = fragment.at_css(%([data-role="agent-bubble"]))
    refute_nil bubble

    run_state = JSON.parse(bubble["data-run-state"])
    assert_equal "debug", run_state.fetch("diagnostic_level")
    assert_equal "running", run_state.fetch("status")
    assert_equal ["task:#{task.id}"], run_state.fetch("activities").map { |activity| activity.fetch("activity_id") }
  end

  test "refresh keeps durable activity preview when projected tool result diverges from raw result" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "shell_exec",
          "requested_name" => "shell_exec",
          "tool_call_id" => "tc_1",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
        body_output: {
          "raw_result" => AgentCore::Resources::Tools::ToolResult.success(text: "secret raw output").to_h,
          "result" => AgentCore::Resources::Tools::ToolResult.success(text: "safe summary").to_h,
          "activity_preview" => "operator preview",
        },
      )

    stream = DAG::NodeEventStream.new(node: task)
    stream.activity_started!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
    )
    stream.activity_finished!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
    )

    get refresh_conversation_messages_path(conversation),
        params: { node_id: agent.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success

    fragment = Nokogiri::HTML.fragment(response.body)
    bubble = fragment.at_css(%([data-role="agent-bubble"]))
    run_state = JSON.parse(bubble["data-run-state"])
    activity = run_state.fetch("activities").sole

    assert_equal "operator preview", activity.fetch("output_preview")
  end
end
