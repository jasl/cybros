require "test_helper"

class Statistics::ToolCallFactBackfillTest < ActiveSupport::TestCase
  test "backfills historical task rows, defaults old runtime origin, and stays idempotent" do
    conversation = create_conversation!
    conversation.update_column("metadata", { "agent" => { "agent_profile" => "coding" } })

    graph = conversation.root_graph
    lane_id = graph.main_lane.id
    turn_id = uuidv7

    agent =
      create_agent_node!(
        graph: graph,
        lane_id: lane_id,
        turn_id: turn_id,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
      )

    success_task =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "read_file",
        tool_call_id: "tc_success",
        source: "files",
        result: AgentCore::Resources::Tools::ToolResult.success(text: "done"),
      )

    failure_task =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "shell_exec",
        tool_call_id: "tc_failure",
        source: "shell",
        result: AgentCore::Resources::Tools::ToolResult.error(text: "upstream exploded"),
      )

    preflight_task =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
        tool_call_id: "tc_preflight",
        source: "system",
      )

    Statistics::ToolCallFact.delete_all
    scope = DAG::Node.where(id: [success_task.id, failure_task.id, preflight_task.id])

    result = Statistics::ToolCallFactBackfill.backfill!(scope: scope)

    assert_equal 3, result.fetch(:scanned)
    assert_equal 2, result.fetch(:projected)
    assert_equal 1, result.fetch(:skipped)
    assert_equal 2, Statistics::ToolCallFact.count

    success_fact = Statistics::ToolCallFact.find_by!(task_node_id: success_task.id)
    failure_fact = Statistics::ToolCallFact.find_by!(task_node_id: failure_task.id)

    assert_equal "runtime", success_fact.sample_origin
    assert_equal "success", success_fact.tool_outcome

    assert_equal "runtime", failure_fact.sample_origin
    assert_equal "failed", failure_fact.tool_outcome
    assert_equal "unknown", failure_fact.failure_class

    assert_nil Statistics::ToolCallFact.find_by(task_node_id: preflight_task.id)

    assert_no_difference("Statistics::ToolCallFact.count") do
      rerun = Statistics::ToolCallFactBackfill.backfill!(scope: scope)

      assert_equal result.fetch(:scanned), rerun.fetch(:scanned)
      assert_equal result.fetch(:projected), rerun.fetch(:projected)
      assert_equal result.fetch(:skipped), rerun.fetch(:skipped)
    end
  end

  private

    def create_agent_node!(graph:, lane_id:, turn_id:, provider_key:, model_ref:)
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane_id,
        turn_id: turn_id,
        metadata: {},
        body_output: {
          "content" => "working",
          "provider_key" => provider_key,
          "model_ref" => model_ref,
        },
      )
    end

    def create_connected_task!(
      graph:,
      from_node:,
      lane_id:,
      turn_id:,
      state:,
      name:,
      tool_call_id:,
      source:,
      result: nil
    )
      task = nil

      ApplicationRecord.transaction do
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
              "arguments" => {},
              "arguments_summary" => "{}",
              "name_resolution" => "exact",
              "arguments_resolution" => "original",
              "source" => source,
            },
            body_output: result ? { "result" => result.to_h } : {},
          )

        graph.edges.create!(
          graph_id: graph.id,
          from_node_id: from_node.id,
          to_node_id: task.id,
          edge_type: DAG::Edge::SEQUENCE,
          metadata: {},
        )
      end

      task
    end

    def uuidv7
      ActiveRecord::Base.with_connection do |connection|
        connection.select_value("select uuidv7()")
      end
    end
end
