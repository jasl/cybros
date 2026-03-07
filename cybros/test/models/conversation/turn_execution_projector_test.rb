require "test_helper"

class Conversation::TurnExecutionProjectorTest < ActiveSupport::TestCase
  test "projects same-turn task nodes into one turn execution" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    first = conversation.append_user_message!(content: "Hello")
    agent = first.fetch(:agent_node)
    agent.mark_running!

    compact_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
      )
    search_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "memory_search",
        tool_call_id: "tc_search",
      )
    read_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::RUNNING,
        name: "read_file",
        tool_call_id: "tc_read",
      )

    second = conversation.append_user_message!(content: "Second turn")
    ignored_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: second.fetch(:agent_node).turn_id,
        state: DAG::Node::RUNNING,
        name: "should_not_project",
        tool_call_id: "tc_other",
      )

    execution = conversation.turn_execution_for_turn_id(agent.turn_id)

    assert_equal agent.turn_id, execution.fetch("turn_id")
    assert_equal agent.id, execution.fetch("anchor_node_id")
    assert_equal "running", execution.fetch("status")
    assert_equal "execution", execution.fetch("phase")
    assert_equal 3, execution.dig("summary", "activity_count")

    activity_source_ids = execution.fetch("activities").map { |activity| activity.fetch("source_node_id") }
    assert_equal [compact_task.id, search_task.id, read_task.id], activity_source_ids
    refute_includes activity_source_ids, ignored_task.id

    assert_equal(
      [
        ["preflight_task", "completed"],
        ["tool_call", "completed"],
        ["tool_call", "running"],
      ],
      execution.fetch("activities").map { |activity| [activity.fetch("kind"), activity.fetch("status")] }
    )
  end

  test "assigns stable activity sequence order for concise execution timeline" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    a =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
      )
    b =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "memory_search",
        tool_call_id: "tc_1",
      )
    c =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::AWAITING_APPROVAL,
        name: "write_file",
        tool_call_id: "tc_2",
      )

    execution = conversation.turn_execution_for_node_id(agent.id)

    assert_equal "awaiting_approval", execution.fetch("status")
    assert_equal "authorization", execution.fetch("phase")
    assert_equal(
      [
        [1, a.id],
        [2, b.id],
        [3, c.id],
      ],
      execution.fetch("activities").map { |activity| [activity.fetch("sequence"), activity.fetch("source_node_id")] }
    )
  end

  test "message_for_node_id derives run_state from the turn execution projector" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    compact_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
      )
    tool_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::RUNNING,
        name: "memory_search",
        tool_call_id: "tc_1",
      )

    message = conversation.message_for_node_id(node_id: agent.id, mode: :full)

    assert_equal agent.id, message.fetch("node_id")

    run_state = message.fetch("run_state")
    assert_equal "running", run_state.fetch("status")
    assert_equal "execution", run_state.fetch("phase")
    assert_equal "standard", run_state.fetch("diagnostic_level")
    assert_equal 1, run_state.dig("summary", "activity_count")
    assert_equal [tool_task.id], run_state.fetch("activities").map { |activity| activity.fetch("source_node_id") }
    refute_includes run_state.fetch("activities").map { |activity| activity.fetch("source_node_id") }, compact_task.id
  end

  private

    def create_task!(graph:, lane_id:, turn_id:, state:, name:, tool_call_id: nil)
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: state,
        lane_id: lane_id,
        turn_id: turn_id,
        metadata: {},
        body_input: {
          "name" => name,
          "requested_name" => name,
          "tool_call_id" => tool_call_id,
          "arguments" => {},
          "arguments_summary" => "{}",
        }.compact,
        body_output: {
          "result" => {
            "ok" => state == DAG::Node::FINISHED,
            "tool_call_id" => tool_call_id,
          }.compact,
        },
      )
    end
end
