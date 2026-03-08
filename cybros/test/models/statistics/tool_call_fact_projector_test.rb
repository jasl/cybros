require "test_helper"

class Statistics::ToolCallFactProjectorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Statistics::ToolCallFact.delete_all
  end

  teardown do
    Statistics::ToolCallFact.delete_all
  end

  test "projects one executable task row and upserts lifecycle updates" do
    conversation = create_conversation!
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

    task = nil

    assert_difference("Statistics::ToolCallFact.count", 1) do
      task =
        create_connected_task!(
          graph: graph,
          from_node: agent,
          lane_id: lane_id,
          turn_id: turn_id,
          state: DAG::Node::PENDING,
          name: "shell_exec",
          requested_name: "shell.exec",
          tool_call_id: "tc_1",
          source: "shell",
          arguments: { "command" => "echo hi" },
          name_resolution: "alias",
        )
    end

    fact = Statistics::ToolCallFact.find_by!(task_node_id: task.id)

    assert_equal conversation.id, fact.conversation_id
    assert_equal conversation.root_conversation_id, fact.root_conversation_id
    assert_equal conversation.user_id, fact.user_id
    assert_equal graph.id, fact.graph_id
    assert_equal turn_id, fact.turn_id
    assert_equal "runtime", fact.sample_origin
    assert_equal "parent", fact.execution_scope
    assert_equal "tc_1", fact.tool_call_id
    assert_equal "shell.exec", fact.requested_name
    assert_equal "shell_exec", fact.resolved_name
    assert_equal "alias", fact.name_resolution
    assert_equal "original", fact.arguments_resolution
    assert_equal "first_pass", fact.model_attempt_class
    assert_equal "shell", fact.source
    assert_equal "openai", fact.provider_key
    assert_equal "openai/gpt-5.4", fact.model_ref
    assert_equal "executable", fact.execution_readiness
    assert_equal false, fact.entered_execution
    assert_equal "not_executed", fact.tool_outcome

    task.mark_running!
    fact.reload

    assert_equal true, fact.entered_execution
    assert_equal "executable", fact.execution_readiness
    assert_equal "not_executed", fact.tool_outcome
    assert_equal task.started_at.to_i, fact.started_at.to_i

    task.mark_finished!(
      payload: {
        "result" => AgentCore::Resources::Tools::ToolResult.success(text: "ok").to_h,
      }
    )

    fact.reload

    assert_equal true, fact.entered_execution
    assert_equal "success", fact.tool_outcome
    assert_equal task.finished_at.to_i, fact.finished_at.to_i
    assert_equal task.finished_at.to_date, fact.effective_on
    assert_operator fact.duration_ms, :>=, 0
    assert_equal 1, Statistics::ToolCallFact.where(task_node_id: task.id).count

    Statistics::ToolCallFactProjector.project!(task.reload)

    assert_equal 1, Statistics::ToolCallFact.where(task_node_id: task.id).count
  end

  test "ignores preflight tasks and derives non-executable readiness states" do
    conversation = create_conversation!
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

    assert_no_difference("Statistics::ToolCallFact.count") do
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
        requested_name: "compact_context",
        tool_call_id: "tc_preflight",
        source: "system",
      )
    end

    invalid_args =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "write_file",
        tool_call_id: "tc_invalid",
        source: "invalid_args",
        arguments_resolution: "invalid",
        result: AgentCore::Resources::Tools::ToolResult.error(text: "Invalid tool arguments (schema_invalid)."),
      )

    policy_denied =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "write_file",
        tool_call_id: "tc_policy",
        source: "policy",
        result: AgentCore::Resources::Tools::ToolResult.error(
          text: "Tool 'write_file' denied by policy (reason=no_write)."
        ),
      )

    approval =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::AWAITING_APPROVAL,
        name: "write_file",
        tool_call_id: "tc_approval",
        source: "files",
        metadata: {
          "approval" => {
            "required" => true,
            "deny_effect" => "block",
            "reason" => "needs_human",
          },
        },
      )

    invalid_fact = Statistics::ToolCallFact.find_by!(task_node_id: invalid_args.id)
    policy_fact = Statistics::ToolCallFact.find_by!(task_node_id: policy_denied.id)
    approval_fact = Statistics::ToolCallFact.find_by!(task_node_id: approval.id)

    assert_equal "invalid_args", invalid_fact.execution_readiness
    assert_equal false, invalid_fact.entered_execution
    assert_equal "not_executed", invalid_fact.tool_outcome

    assert_equal "policy_denied", policy_fact.execution_readiness
    assert_equal false, policy_fact.entered_execution
    assert_equal "not_executed", policy_fact.tool_outcome

    assert_equal "awaiting_approval", approval_fact.execution_readiness
    assert_equal false, approval_fact.entered_execution
    assert_equal "not_executed", approval_fact.tool_outcome

    approval.deny_approval!(reason: "approval_denied")
    approval_fact.reload

    assert_equal "approval_rejected", approval_fact.execution_readiness
    assert_equal false, approval_fact.entered_execution
    assert_equal "not_executed", approval_fact.tool_outcome
  end

  test "manual retry rows mark manual_retry and preserve retry_of_task_node_id" do
    conversation = create_conversation!
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

    original_started_at = Time.current - 5.seconds
    original_finished_at = Time.current - 4.seconds

    original =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::ERRORED,
        name: "shell_exec",
        tool_call_id: "tc_retry",
        source: "shell",
        arguments_resolution: "repaired",
        repair: { "arguments" => true },
        started_at: original_started_at,
        finished_at: original_finished_at,
        metadata: { "error" => "RuntimeError: boom" },
      )

    retried = original.retry!

    original_fact = Statistics::ToolCallFact.find_by!(task_node_id: original.id)
    retry_fact = Statistics::ToolCallFact.find_by!(task_node_id: retried.id)

    assert_equal "failed", original_fact.tool_outcome
    assert_equal true, original_fact.entered_execution
    assert_equal "repaired_args", original_fact.model_attempt_class

    assert_equal true, retry_fact.manual_retry
    assert_equal original.id, retry_fact.retry_of_task_node_id
    assert_equal "repaired_args", retry_fact.model_attempt_class
    assert_equal "executable", retry_fact.execution_readiness
    assert_equal false, retry_fact.entered_execution
    assert_equal "not_executed", retry_fact.tool_outcome
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
      requested_name: nil,
      tool_call_id: nil,
      source: "shell",
      arguments: {},
      name_resolution: "exact",
      arguments_resolution: "original",
      repair: nil,
      result: nil,
      metadata: {},
      started_at: nil,
      finished_at: nil
    )
      task = nil

      ApplicationRecord.transaction do
        task =
          graph.nodes.create!(
            node_type: Messages::Task.node_type_key,
            state: state,
            lane_id: lane_id,
            turn_id: turn_id,
            metadata: metadata,
            started_at: started_at,
            finished_at: finished_at,
            body_input: {
              "name" => name,
              "requested_name" => requested_name || name,
              "tool_call_id" => tool_call_id,
              "arguments" => arguments,
              "arguments_summary" => arguments.to_json,
              "name_resolution" => name_resolution,
              "arguments_resolution" => arguments_resolution,
              "source" => source,
              "repair" => repair,
            }.compact,
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
