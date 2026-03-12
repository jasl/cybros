require "test_helper"

class TurnInternalTaskResetTest < ActiveSupport::TestCase
  test "regenerate cancels turn-internal rows and clears materialized task nodes while preserving user input" do
    conversation = create_conversation!(title: "Reset queue rows")
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    user_node = nil
    agent_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Reset this turn",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: { "llm" => { "model_ref" => Account.instance.llm_default_model_ref } },
          body_output: { "content" => "Original answer" },
        )

      m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    materialized_task = nil
    graph.mutate!(turn_id: turn_id) do |m|
      materialized_task =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          body_input: {
            "tool_call_id" => "queued-reset:task",
            "name" => "subagent_run",
            "requested_name" => "subagent_run",
            "arguments" => { "name" => "worker", "prompt" => "Summarize" },
            "arguments_summary" => "{\"name\":\"worker\",\"prompt\":\"Summarize\"}",
          },
          metadata: { "generated_by" => "turn_internal_task_queue" },
        )

      m.create_edge(from_node: user_node, to_node: materialized_task, edge_type: DAG::Edge::SEQUENCE)
    end

    queued =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: graph,
        lane: lane,
        turn_id: turn_id,
        source_node: user_node,
        source_hook_name: "after_task_notice",
        source_fingerprint: "reset-queued",
        logical_tool_name: "subagent_run",
        input: { "name" => "queued", "prompt" => "Queued follow-up" },
        authored_metadata: {},
        execution_mode: "parallel_safe",
        queue_position: 10,
        status: "queued",
      )
    materialized =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: graph,
        lane: lane,
        turn_id: turn_id,
        source_node: user_node,
        source_hook_name: "after_task_notice",
        source_fingerprint: "reset-materialized",
        logical_tool_name: "subagent_run",
        input: { "name" => "materialized", "prompt" => "Materialized follow-up" },
        authored_metadata: {},
        execution_mode: "parallel_safe",
        queue_position: 20,
        status: "materialized",
        materialized_task_node: materialized_task,
      )

    result = conversation.regenerate!(agent_node_id: agent_node.id)

    assert_equal :in_place, result.fetch(:mode)
    replacement = result.fetch(:node)

    assert_equal DAG::Node::PENDING, replacement.reload.state
    assert_equal turn_id, replacement.turn_id
    assert_nil user_node.reload.compressed_at
    assert_equal "Reset this turn", user_node.body_input.fetch("content")

    assert_equal "canceled", queued.reload.status
    assert_equal "turn_reset", queued.canceled_reason
    assert_equal "canceled", materialized.reload.status
    assert_equal "turn_reset", materialized.canceled_reason
    assert materialized_task.reload.compressed_at.present?

    assert_empty TurnInternalTasks::Materializer.materialize_ready!(graph: graph)
  end
end
