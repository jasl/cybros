require "test_helper"

class Conversation::TurnExecutionProjectionVisibilityTest < ActiveSupport::TestCase
  test "assistant bubble projection includes compact_context alongside ordinary tool activity" do
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

    projector = Conversation::TurnExecutionProjector.new(conversation: conversation)
    execution = projector.turn_execution_for_turn_id(agent.turn_id)
    run_state = projector.run_state_for_node_id(agent.id)

    assert_equal [compact_task.id, tool_task.id], execution.fetch("activities").map { |activity| activity.fetch("source_node_id") }
    assert_equal ["assistant_bubble", "assistant_bubble"], execution.fetch("activities").map { |activity| activity.fetch("visibility") }

    assert_equal [compact_task.id, tool_task.id], run_state.fetch("activities").map { |activity| activity.fetch("source_node_id") }
    assert_equal ["assistant_bubble", "assistant_bubble"], run_state.fetch("activities").map { |activity| activity.fetch("visibility") }
  end

  test "run_state is nil for non assistant messages even when the turn has activities" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    user = turn.fetch(:user_node)
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    create_task!(
      graph: graph,
      lane_id: conversation.chat_lane.id,
      turn_id: agent.turn_id,
      state: DAG::Node::RUNNING,
      name: "memory_search",
      tool_call_id: "tc_1",
    )

    message = conversation.message_for_node_id(node_id: user.id, mode: :full)

    assert_nil message["run_state"]
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
      )
    end
end
