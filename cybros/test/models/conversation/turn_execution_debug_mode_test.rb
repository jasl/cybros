require "test_helper"

class Conversation::TurnExecutionDebugModeTest < ActiveSupport::TestCase
  test "projector keeps canonical identity stable while debug adds richer diagnostics" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

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

    stream = DAG::NodeEventStream.new(node: task)
    stream.activity_started!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
      data: { "executor" => "task_executor" },
    )
    last_event =
      stream.activity_failed!(
        activity_id: "task:#{task.id}",
        activity_kind: "tool_call",
        phase: "execution",
        data: { "error" => "boom", "executor" => "task_executor" },
      )

    standard = conversation.turn_execution_for_node_id(agent.id)
    standard_activity = standard.fetch("activities").sole

    assert_equal "standard", standard.fetch("diagnostic_level")
    assert_equal last_event.id, standard.fetch("event_cursor")
    assert_equal last_event.id, standard_activity.fetch("last_event_id")
    assert_nil standard_activity["diagnostics"]

    agent.update!(
      metadata: agent.metadata.deep_merge("turn_execution" => { "diagnostic_level" => "debug" }),
    )

    debug = conversation.turn_execution_for_node_id(agent.id)
    debug_activity = debug.fetch("activities").sole

    assert_equal "debug", debug.fetch("diagnostic_level")
    assert_equal(
      standard.fetch("activities").map { |activity| activity.slice("activity_id", "kind", "status", "phase", "source_node_id", "sequence") },
      debug.fetch("activities").map { |activity| activity.slice("activity_id", "kind", "status", "phase", "source_node_id", "sequence") },
    )
    assert_equal last_event.id, debug_activity.fetch("last_event_id")
    assert_equal "activity_failed", debug_activity.dig("diagnostics", "last_event_kind")
    assert_equal({ "error" => "boom", "executor" => "task_executor" }, debug_activity.dig("diagnostics", "last_event_data"))
  end

  test "turn diagnostic level can be set through internal creation and retry flags" do
    conversation = create_conversation!(title: "Chat")

    created = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
    agent = created.fetch(:agent_node)
    run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: agent.id)

    assert_equal "debug", agent.reload.metadata.dig("turn_execution", "diagnostic_level")
    assert_equal "debug", run.reload.debug.dig("turn_execution", "diagnostic_level")

    agent.mark_running!
    agent.mark_errored!(error: "boom")

    retried_id = conversation.retry_agent_node!(failed_node_id: agent.id, diagnostic_level: "debug")
    retried = conversation.root_graph.nodes.find(retried_id)
    retried_run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: retried.id)

    assert_equal "debug", retried.reload.metadata.dig("turn_execution", "diagnostic_level")
    assert_equal "debug", retried_run.reload.debug.dig("turn_execution", "diagnostic_level")
  end
end
