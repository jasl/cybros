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

  test "turn execution cursor only advances for replay-relevant execution events" do
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

    activity_event =
      DAG::NodeEventStream.new(node: tool_task).activity_started!(
        activity_id: "task:#{tool_task.id}",
        activity_kind: "tool_call",
        phase: "execution",
      )

    turn_record = graph.turns.find(agent.turn_id)
    assert_equal activity_event.id, turn_record.execution_event_cursor

    progress_event =
      DAG::NodeEvent.create!(
        graph: graph,
        node: tool_task,
        turn_id: agent.turn_id,
        kind: DAG::NodeEvent::PROGRESS,
        payload: { "phase" => "execution", "message" => "still running" },
      )
    assert progress_event.persisted?

    turn_record.reload
    assert_equal activity_event.id, turn_record.execution_event_cursor

    original_refresh = DAG::Turn.method(:refresh_execution_rollups!)
    DAG::Turn.define_singleton_method(:refresh_execution_rollups!) do |**_kwargs|
      raise "assistant output events should not trigger a full rollup refresh"
    end

    output_event =
      DAG::NodeEvent.create!(
        graph: graph,
        node: agent,
        turn_id: agent.turn_id,
        kind: DAG::NodeEvent::OUTPUT_DELTA,
        text: "Partial answer",
        payload: {},
      )

    turn_record.reload
    assert_equal output_event.id, turn_record.execution_event_cursor
  ensure
    DAG::Turn.define_singleton_method(:refresh_execution_rollups!, original_refresh) if original_refresh
  end

  test "compression refreshes persisted turn rollups when finished task activity is folded away" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
    next_turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")

    user =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_input: { "content" => "Hello" },
        metadata: {},
      )
    agent =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_output: { "content" => "Done" },
        metadata: {},
      )
    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        metadata: {},
        body_input: {
          "name" => "memory_search",
          "requested_name" => "memory_search",
          "tool_call_id" => "tc_fold",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )
    next_user =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: next_turn_id,
        body_input: { "content" => "Next" },
        metadata: {},
      )

    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: agent.id, to_node_id: task.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: task.id, to_node_id: next_user.id, edge_type: DAG::Edge::SEQUENCE)

    DAG::NodeEventStream.new(node: task).activity_finished!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
    )

    persisted_turn = graph.turns.find(turn_id)
    assert_equal 1, persisted_turn.execution_activity_count

    graph.compress!(node_ids: [task.id], summary_content: "compressed", summary_metadata: {})

    persisted_turn.reload
    assert_equal 0, persisted_turn.execution_activity_count
    assert_equal [], persisted_turn.execution_preview_activities
  end
end
