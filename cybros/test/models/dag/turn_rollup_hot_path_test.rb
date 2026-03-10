require "test_helper"

class DAG::TurnRollupHotPathTest < ActiveSupport::TestCase
  test "turn stores execution rollup fields for the assistant-bubble hot path" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    tool_task =
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

    event =
      DAG::NodeEventStream.new(node: tool_task).activity_started!(
        activity_id: "task:#{tool_task.id}",
        activity_kind: "tool_call",
        phase: "execution",
      )

    persisted_turn = graph.turns.find(agent.turn_id)

    assert_includes DAG::Turn.column_names, "execution_status"
    assert_includes DAG::Turn.column_names, "execution_phase"
    assert_includes DAG::Turn.column_names, "execution_diagnostic_level"
    assert_includes DAG::Turn.column_names, "execution_event_cursor"
    assert_includes DAG::Turn.column_names, "execution_summary"
    assert_includes DAG::Turn.column_names, "execution_preview_activities"
    assert_includes DAG::Turn.column_names, "execution_activity_count"
    assert_includes DAG::Turn.column_names, "execution_updated_at"

    assert_equal "running", persisted_turn.execution_status
    assert_equal "execution", persisted_turn.execution_phase
    assert_equal "standard", persisted_turn.execution_diagnostic_level
    assert_equal event.id, persisted_turn.execution_event_cursor
    assert_equal 1, persisted_turn.execution_summary.fetch("activity_count")
    assert_equal [tool_task.id], persisted_turn.execution_preview_activities.map { |activity| activity.fetch("source_node_id") }
    assert persisted_turn.execution_updated_at.present?

    row =
      graph.turns
        .where(id: agent.turn_id)
        .pick(
          :execution_status,
          :execution_phase,
          :execution_diagnostic_level,
          :execution_event_cursor,
          :execution_activity_count,
        )
    assert_equal ["running", "execution", "standard", event.id, 1], row
  end
end
