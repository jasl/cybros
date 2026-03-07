require "test_helper"

class Conversation::MessageRunStateProjectionTest < ActiveSupport::TestCase
  test "message_for_node_id and message_page project run_state from turn_execution" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    compact_task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: { "name" => "compact_context", "requested_name" => "compact_context" },
      )
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

    stream = DAG::NodeEventStream.new(node: tool_task)
    last_event =
      stream.activity_started!(
        activity_id: "task:#{tool_task.id}",
        activity_kind: "tool_call",
        phase: "execution",
        diagnostic_level: "debug",
        data: { "executor" => "task_executor" },
      )

    direct = conversation.message_for_node_id(node_id: agent.id, mode: :full)
    from_page =
      conversation.message_page(limit: 20, mode: :full)
        .fetch("messages")
        .find { |message| message.fetch("node_id") == agent.id }

    [direct, from_page].each do |message|
      run_state = message.fetch("run_state")
      assert_equal "running", run_state.fetch("status")
      assert_equal "execution", run_state.fetch("phase")
      assert_equal "debug", run_state.fetch("diagnostic_level")
      assert_equal last_event.id, run_state.fetch("event_cursor")
      assert_equal 1, run_state.dig("summary", "activity_count")
      assert_equal [tool_task.id], run_state.fetch("activities").map { |activity| activity.fetch("source_node_id") }
      refute_includes run_state.fetch("activities").map { |activity| activity.fetch("source_node_id") }, compact_task.id
      assert_equal "activity_started", run_state.dig("activities", 0, "diagnostics", "last_event_kind")
    end
  end
end
