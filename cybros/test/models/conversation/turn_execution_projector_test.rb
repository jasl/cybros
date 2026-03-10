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
    assert_equal first.fetch(:user_node).id, execution.fetch("head_node_id")
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

  test "running activity status and phase win over awaiting approval when both are active" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    waiting_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::AWAITING_APPROVAL,
        name: "write_file",
        tool_call_id: "tc_wait",
      )
    running_task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::RUNNING,
        name: "read_file",
        tool_call_id: "tc_run",
      )

    DAG::NodeEventStream.new(node: waiting_task).activity_waiting!(
      activity_id: "task:#{waiting_task.id}",
      activity_kind: "tool_call",
      phase: "authorization",
    )
    DAG::NodeEventStream.new(node: running_task).activity_started!(
      activity_id: "task:#{running_task.id}",
      activity_kind: "tool_call",
      phase: "execution",
    )

    execution = conversation.turn_execution_for_turn_id(agent.turn_id)

    assert_equal "running", execution.fetch("status")
    assert_equal "execution", execution.fetch("phase")
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

  test "message run_state keeps a bounded assistant-bubble preview while turn execution stays full" do
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

    visible_tasks =
      5.times.map do |index|
        create_task!(
          graph: graph,
          lane_id: conversation.chat_lane.id,
          turn_id: agent.turn_id,
          state: index == 4 ? DAG::Node::RUNNING : DAG::Node::FINISHED,
          name: "tool_#{index}",
          tool_call_id: "tc_#{index}",
        )
      end

    execution = conversation.turn_execution_for_turn_id(agent.turn_id)
    message = conversation.message_for_node_id(node_id: agent.id, mode: :full)
    run_state = message.fetch("run_state")

    assert_equal 6, execution.fetch("activities").length
    assert_equal 5, run_state.dig("summary", "activity_count")
    assert_equal 3, run_state.fetch("activities").length
    assert_equal visible_tasks.last(3).map(&:id), run_state.fetch("activities").map { |activity| activity.fetch("source_node_id") }
    refute_includes run_state.fetch("activities").map { |activity| activity.fetch("source_node_id") }, compact_task.id
  end

  test "activity output preview uses durable activity preview when projected result differs" do
    conversation = create_conversation!(title: "Chat")
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
          "raw_result" => AgentCore::Resources::Tools::ToolResult.success(text: "raw operator detail").to_h,
          "result" => AgentCore::Resources::Tools::ToolResult.success(text: "projected summary").to_h,
          "activity_preview" => "operator-visible activity preview",
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

    execution = conversation.turn_execution_for_turn_id(agent.turn_id)
    activity = execution.fetch("activities").sole

    assert_equal "operator-visible activity preview", activity.fetch("output_preview")
  end

  test "task-heavy turns expose execution rollups on dag_turns" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    task =
      create_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::RUNNING,
        name: "memory_search",
        tool_call_id: "tc_rollup",
      )

    turn_record = graph.turns.find(agent.turn_id)
    assert_equal "running", turn_record.execution_status
    assert_equal 1, turn_record.execution_activity_count
    assert turn_record.execution_updated_at.present?

    task.mark_finished!(content: "done")
    agent.mark_finished!(content: "All set")

    turn_record.reload
    assert_equal "completed", turn_record.execution_status
    assert_equal 1, turn_record.execution_activity_count
    assert turn_record.execution_updated_at.present?
  end

  test "run_state preview does not require full turn execution drill-down" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    create_task!(
      graph: graph,
      lane_id: conversation.chat_lane.id,
      turn_id: agent.turn_id,
      state: DAG::Node::RUNNING,
      name: "memory_search",
      tool_call_id: "tc_preview",
    )

    projector = Conversation::TurnExecutionProjector.new(conversation: conversation)
    execution = projector.turn_execution_for_turn_id(agent.turn_id)
    assert_equal 1, execution.fetch("activities").length

    preview_projector = Conversation::TurnExecutionProjector.new(conversation: conversation)
    preview_projector.define_singleton_method(:turn_execution_for_turn_id) do |_turn_id|
      raise "preview should not depend on full drill-down"
    end

    run_state = preview_projector.run_state_for_node_id(agent.id)
    assert_equal "running", run_state.fetch("status")
    assert_equal 1, run_state.dig("summary", "activity_count")
    assert_equal 1, run_state.fetch("activities").length
  end

  test "run_state nil does not require full turn execution drill-down when rollup has no visible activity" do
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
    DAG::NodeEventStream.new(node: compact_task).activity_finished!(
      activity_id: "task:#{compact_task.id}",
      activity_kind: "preflight_task",
      phase: "preflight",
    )

    preview_projector = Conversation::TurnExecutionProjector.new(conversation: conversation)
    preview_projector.define_singleton_method(:turn_execution_for_turn_id) do |_turn_id|
      raise "empty run_state should not depend on full drill-down"
    end

    assert_nil preview_projector.run_state_for_node_id(agent.id)
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
