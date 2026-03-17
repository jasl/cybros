require "test_helper"

class Conversation::TurnExecutionSubagentActivityTest < ActiveSupport::TestCase
  test "projects the latest parent-side subagent state with runtime-owned subagent links" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    child = create_subagent_runtime_conversation!(user: conversation.user, hidden_task_name: "child_internal_task")

    create_subagent_task!(
      graph: graph,
      lane_id: conversation.chat_lane.id,
      turn_id: agent.turn_id,
      state: DAG::Node::FINISHED,
      name: "subagent_run",
      tool_call_id: "tc_run",
      arguments: { "name" => "Research Agent" },
      payload: subagent_payload(
        child: child,
        status: "running",
        counts: { "pending" => 0, "running" => 1, "awaiting_approval" => 0 },
        transcript_lines: ["U:child: hello", "A:child: investigating"],
      ),
    )
    wait_task =
      create_subagent_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "subagent_wait",
        tool_call_id: "tc_wait",
        arguments: { "subagent_id" => child.metadata.dig("subagent", "subagent_id") },
        payload: subagent_payload(
          child: child,
          status: "idle",
          counts: { "pending" => 0, "running" => 0, "awaiting_approval" => 0 },
          transcript_lines: ["U:child: hello", "A:child: done"],
          wait_status: "settled",
          timed_out: false,
          timeout_ms: 5,
          elapsed_ms: 1,
        ),
      )

    execution = conversation.turn_execution_for_turn_id(agent.turn_id)

    assert_equal "running", execution.fetch("status")
    assert_equal ["subagent"], execution.fetch("activities").map { |activity| activity.fetch("kind") }

    wait_activity = execution.fetch("activities").sole

    assert_equal wait_task.id, wait_activity.fetch("source_node_id")
    assert_equal "completed", wait_activity.fetch("status")
    assert_equal "terminal", wait_activity.fetch("phase")
    assert_equal child.metadata.dig("subagent", "subagent_id"), wait_activity.dig("links", "subagent_id")
    assert_equal "idle", wait_activity.dig("snapshot", "status")
    assert_equal "settled", wait_activity.dig("snapshot", "wait_status")
    assert_equal false, wait_activity.dig("snapshot", "timed_out")
    assert_equal 5, wait_activity.dig("snapshot", "timeout_ms")
    assert_equal 1, wait_activity.dig("snapshot", "elapsed_ms")
  end

  test "debug mode keeps canonical subagent activity shape stable while adding richer subagent diagnostics" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    child = create_subagent_runtime_conversation!(user: conversation.user)

    task =
      create_subagent_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "subagent_wait",
        tool_call_id: "tc_wait",
        arguments: { "subagent_id" => child.metadata.dig("subagent", "subagent_id") },
        payload: subagent_payload(
          child: child,
          status: "running",
          counts: { "pending" => 0, "running" => 1, "awaiting_approval" => 0 },
          transcript_lines: ["U:child: hello", "A:child: partial"],
          wait_status: "timeout",
          timed_out: true,
          timeout_ms: 10,
          elapsed_ms: 10,
        ),
      )

    standard = conversation.turn_execution_for_node_id(agent.id)
    standard_activity = standard.fetch("activities").sole

    assert_equal "subagent", standard_activity.fetch("kind")
    assert_equal "running", standard_activity.fetch("status")
    assert_nil standard_activity["diagnostics"]

    agent.update!(
      metadata: agent.metadata.deep_merge("turn_execution" => { "diagnostic_level" => "debug" }),
    )

    debug = conversation.turn_execution_for_node_id(agent.id)
    debug_activity = debug.fetch("activities").sole

    assert_equal(
      standard.fetch("activities").map { |activity| activity.slice("activity_id", "kind", "status", "phase", "source_node_id", "sequence", "links", "snapshot") },
      debug.fetch("activities").map { |activity| activity.slice("activity_id", "kind", "status", "phase", "source_node_id", "sequence", "links", "snapshot") },
    )
    assert_equal task.node_events.order(:id).last.id, debug_activity.fetch("last_event_id")
    assert_equal "activity_finished", debug_activity.dig("diagnostics", "last_event_kind")
    assert_equal "running", debug_activity.dig("diagnostics", "subagent", "status")
    assert_equal "timeout", debug_activity.dig("diagnostics", "subagent", "wait_status")
    assert_equal true, debug_activity.dig("diagnostics", "subagent", "timed_out")
    assert_equal ["U:child: hello", "A:child: partial"], debug_activity.dig("diagnostics", "subagent", "transcript_lines")
  end

  test "collapses settled subagent wait over the initial run snapshot once the parent turn finishes" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    child = create_subagent_runtime_conversation!(user: conversation.user)

    create_subagent_task!(
      graph: graph,
      lane_id: conversation.chat_lane.id,
      turn_id: agent.turn_id,
      state: DAG::Node::FINISHED,
      name: "subagent_run",
      tool_call_id: "tc_run",
      arguments: { "name" => "Research Agent" },
      payload: subagent_payload(
        child: child,
        status: "pending",
        counts: { "pending" => 1, "running" => 0, "awaiting_approval" => 0 },
        transcript_lines: ["U:child: hello", "A:"],
      ),
    )
    wait_task =
      create_subagent_task!(
        graph: graph,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        state: DAG::Node::FINISHED,
        name: "subagent_wait",
        tool_call_id: "tc_wait",
        arguments: { "subagent_id" => child.metadata.dig("subagent", "subagent_id") },
        payload: subagent_payload(
          child: child,
          status: "idle",
          counts: { "pending" => 0, "running" => 0, "awaiting_approval" => 0 },
          transcript_lines: ["U:child: hello", "A:child: done"],
          wait_status: "settled",
          timed_out: false,
          timeout_ms: 5,
          elapsed_ms: 1,
        ),
      )
    agent.mark_finished!(content: "done")

    execution = conversation.turn_execution_for_turn_id(agent.turn_id)

    assert_equal "completed", execution.fetch("status")
    assert_equal "terminal", execution.fetch("phase")
    assert_equal [wait_task.id], execution.fetch("activities").map { |activity| activity.fetch("source_node_id") }
    assert_equal "completed", execution.fetch("activities").sole.fetch("status")
    assert_equal "settled", execution.fetch("activities").sole.dig("snapshot", "wait_status")
  end

  private

    def create_subagent_runtime_conversation!(user:, hidden_task_name: nil)
      subagent_conversation =
        Conversation.create!(
          user: user,
          title: "Child",
          metadata: {
            "agent" => {
              "key" => "subagent:child",
              "agent_profile" => "subagent",
              "context_turns" => 50,
            },
            "subagent" => {
              "subagent_id" => ActiveRecord::Base.connection.select_value("select uuidv7()"),
            },
          },
        )

      graph = subagent_conversation.dag_graph
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

      graph.mutate!(turn_id: turn_id) do |m|
        user_node =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "child: hello",
            metadata: {},
          )
        agent_node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::RUNNING,
            metadata: { "turn_execution" => { "diagnostic_level" => "debug" } },
          )

        m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

        next if hidden_task_name.blank?

        task =
          m.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::RUNNING,
            metadata: {},
            turn_id: turn_id,
            body_input: {
              "name" => hidden_task_name,
              "requested_name" => hidden_task_name,
              "tool_call_id" => "tc_hidden",
              "arguments" => {},
              "arguments_summary" => "{}",
            },
          )

        m.create_edge(from_node: user_node, to_node: task, edge_type: DAG::Edge::SEQUENCE)
      end

      subagent_conversation
    end

    def create_subagent_task!(graph:, lane_id:, turn_id:, state:, name:, tool_call_id:, arguments:, payload:)
      task =
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
            "arguments" => arguments,
            "arguments_summary" => JSON.generate(arguments),
          },
          body_output: {
            "result" => subagent_result(payload),
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

      task
    end

    def subagent_result(payload)
      AgentCore::Resources::Tools::ToolResult.success(
        text: JSON.generate(payload),
        metadata: { subagent: payload },
      ).to_h
    end

    def subagent_payload(child:, status:, counts:, transcript_lines:, wait_status: nil, timed_out: nil, timeout_ms: nil, elapsed_ms: nil)
      payload = {
        "ok" => true,
        "operation" => wait_status.present? ? "wait" : "run",
        "subagent_id" => child.metadata.dig("subagent", "subagent_id"),
        "status" => status,
        "counts" => counts,
        "leaf" => {
          "node_id" => child.dag_graph.leaf_nodes.where(lane_id: child.dag_graph.main_lane.id).order(:id).last.id.to_s,
          "state" => status == "idle" ? DAG::Node::FINISHED : status,
        },
        "transcript_lines" => transcript_lines,
        "diagnostic_level" => "debug",
      }

      payload["wait_status"] = wait_status unless wait_status.nil?
      payload["timed_out"] = timed_out unless timed_out.nil?
      payload["timeout_ms"] = timeout_ms unless timeout_ms.nil?
      payload["elapsed_ms"] = elapsed_ms unless elapsed_ms.nil?
      payload
    end
end
