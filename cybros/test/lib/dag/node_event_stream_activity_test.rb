require "test_helper"

class DAG::NodeEventStreamActivityTest < ActiveSupport::TestCase
  test "activity lifecycle events are machine readable and sequence ordered" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        metadata: {},
        body_input: { "name" => "memory_search", "tool_call_id" => "tc_1" },
      )

    stream = DAG::NodeEventStream.new(node: task)

    stream.activity_planned!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "planning",
    )
    stream.activity_waiting!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "authorization",
      data: { "reason" => "approval_required" },
    )

    events =
      graph.node_event_page_for(
        task.id,
        limit: 10,
        kinds: [DAG::NodeEvent::ACTIVITY_PLANNED, DAG::NodeEvent::ACTIVITY_WAITING],
      )

    assert_equal [DAG::NodeEvent::ACTIVITY_PLANNED, DAG::NodeEvent::ACTIVITY_WAITING], events.map { |event| event.fetch("kind") }

    planned_payload = events.first.fetch("payload")
    waiting_payload = events.second.fetch("payload")

    assert_equal task.turn_id, planned_payload.fetch("turn_id")
    assert_equal "task:#{task.id}", planned_payload.fetch("activity_id")
    assert_equal "tool_call", planned_payload.fetch("kind")
    assert_equal "planned", planned_payload.fetch("status")
    assert_equal "planning", planned_payload.fetch("phase")
    assert_equal task.id, planned_payload.fetch("source_node_id")
    assert_equal "standard", planned_payload.fetch("diagnostic_level")
    assert_kind_of Integer, planned_payload.fetch("sequence")

    assert_equal "awaiting_approval", waiting_payload.fetch("status")
    assert_equal "authorization", waiting_payload.fetch("phase")
    assert_equal({ "reason" => "approval_required" }, waiting_payload.fetch("data"))
    assert_operator waiting_payload.fetch("sequence"), :>, planned_payload.fetch("sequence")
    assert events.first.fetch("event_id").present?
    assert events.second.fetch("event_id").present?
  end
end
