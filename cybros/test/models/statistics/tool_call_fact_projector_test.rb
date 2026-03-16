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

  test "projects compact_context and derives non-executable readiness states" do
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

    compact_context =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
        requested_name: "compact_context",
        tool_call_id: "tc_compact",
        source: "context_budget_policy",
      )

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

    compact_fact = Statistics::ToolCallFact.find_by!(task_node_id: compact_context.id)
    invalid_fact = Statistics::ToolCallFact.find_by!(task_node_id: invalid_args.id)
    policy_fact = Statistics::ToolCallFact.find_by!(task_node_id: policy_denied.id)
    approval_fact = Statistics::ToolCallFact.find_by!(task_node_id: approval.id)

    assert_equal "compact_context", compact_fact.resolved_name
    assert_equal "context_budget_policy", compact_fact.source
    assert_equal "executable", compact_fact.execution_readiness
    assert_equal "success", compact_fact.tool_outcome
    assert_equal false, compact_fact.entered_execution

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

  test "ordinary branch conversations are not mislabeled as subagent execution scope" do
    parent = create_conversation!
    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Ordinary child",
        agent: parent.agent,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        metadata: { "agent" => { "agent_profile" => "coding" } },
      )

    graph = child.dag_graph
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

    task =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "shell_exec",
        tool_call_id: "tc_child",
        source: "shell",
        result: AgentCore::Resources::Tools::ToolResult.success(text: "ok"),
      )

    fact = Statistics::ToolCallFact.find_by!(task_node_id: task.id)

    assert_equal "parent", fact.execution_scope
    assert_equal parent.root_conversation_id, fact.root_conversation_id
  end

  test "real subagent worker conversations are labeled subagent while parent wrapper tasks stay parent" do
    parent = create_conversation!

    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Subagent child",
        agent: parent.agent,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        metadata: {
          "agent" => {
            "key" => "subagent:child",
            "agent_profile" => "subagent",
            "context_turns" => 50,
          },
          "subagent" => {
            "name" => "child",
            "parent_conversation_id" => parent.id.to_s,
            "parent_graph_id" => parent.dag_graph.id.to_s,
            "spawned_from_node_id" => uuidv7,
          },
          "statistics" => {
            "sample_origin" => "runtime",
          },
        },
      )

    parent_graph = parent.dag_graph
    parent_lane_id = parent_graph.main_lane.id
    parent_turn_id = uuidv7

    parent_agent =
      create_agent_node!(
        graph: parent_graph,
        lane_id: parent_lane_id,
        turn_id: parent_turn_id,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
      )

    parent_task =
      create_connected_task!(
        graph: parent_graph,
        from_node: parent_agent,
        lane_id: parent_lane_id,
        turn_id: parent_turn_id,
        state: DAG::Node::FINISHED,
        name: "subagent_run",
        tool_call_id: "tc_parent_subagent",
        source: "cybros",
        result: AgentCore::Resources::Tools::ToolResult.success(text: "spawned"),
      )

    child_graph = child.dag_graph
    child_lane_id = child_graph.main_lane.id
    child_turn_id = uuidv7

    child_agent =
      create_agent_node!(
        graph: child_graph,
        lane_id: child_lane_id,
        turn_id: child_turn_id,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
      )

    child_task =
      create_connected_task!(
        graph: child_graph,
        from_node: child_agent,
        lane_id: child_lane_id,
        turn_id: child_turn_id,
        state: DAG::Node::FINISHED,
        name: "shell_exec",
        tool_call_id: "tc_child_internal",
        source: "shell",
        result: AgentCore::Resources::Tools::ToolResult.success(text: "ok"),
      )

    parent_fact = Statistics::ToolCallFact.find_by!(task_node_id: parent_task.id)
    child_fact = Statistics::ToolCallFact.find_by!(task_node_id: child_task.id)

    assert_equal "parent", parent_fact.execution_scope
    assert_equal "subagent", child_fact.execution_scope
    assert_equal parent.root_conversation_id, child_fact.root_conversation_id
  end

  test "projects programmable routing and capability snapshot dimensions from task metadata and run snapshot" do
    conversation = create_conversation!
    graph = conversation.root_graph
    lane_id = graph.main_lane.id
    turn_id = uuidv7
    recognized_deployment = recognize_agent_runtime!(agent: conversation.agent)
    provider_credential = LLMProviderCredential.find_by!(provider_key: "dev")

    agent =
      create_agent_node!(
        graph: graph,
        lane_id: lane_id,
        turn_id: turn_id,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
      )

    ConversationRun.create!(
      build_conversation_run_attributes(
        conversation: conversation,
        dag_node_id: agent.id,
        agent: conversation.agent,
        recognized_deployment: recognized_deployment,
        provider_credential: nil,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {},
        agent_config_schema_fingerprint: conversation.agent.config_schema_fingerprint,
        effective_policy: {},
        runtime_governors:
          runtime_governors_snapshot(
            provider_credential: provider_credential,
            selected_model_ref: "openai/gpt-5.4",
            agent: conversation.agent,
          ),
        snapshot: {
          "draft" => {
            "planning" => {
              "tool_surface" => {
                "tool_surface_label" => "bundled_default.before_agent_step",
              },
            },
          },
          "capability_snapshot" => {
            "capability_registry_snapshot_id" => "cap_snapshot_123",
            "kernel_capability_registry_version" => "kernel:v1",
            "agent_capabilities_version" => "default-agent-capabilities:v1",
          },
        },
      ),
    )

    task =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
        requested_name: "compact_context",
        tool_call_id: "tc_programmable",
        source: "agent",
        metadata: {
          "tool" => {
            "logical_tool_name" => "compact_context",
            "effective_tool_id" => "etool_compact",
            "implementation_source" => "agent",
            "implementation_ref" => "agent://compact_context",
            "capability_registry_snapshot_id" => "cap_snapshot_123",
            "tool_surface_id" => "tool_surface_123",
          },
        },
        result: AgentCore::Resources::Tools::ToolResult.success(text: "ok"),
      )

    fact = Statistics::ToolCallFact.find_by!(task_node_id: task.id)

    assert_equal "compact_context", fact.logical_tool_name
    assert_equal "cap_snapshot_123", fact.capability_registry_snapshot_id
    assert_equal "kernel:v1", fact.kernel_capability_registry_version
    assert_equal "tool_surface_123", fact.tool_surface_id
    assert_equal "bundled_default.before_agent_step", fact.tool_surface_label
    assert_equal "agent", fact.implementation_source
    assert_equal "agent://compact_context", fact.implementation_ref
    assert_equal recognized_deployment.id, fact.recognized_deployment_id
    assert_equal recognized_deployment.recognized_deployment_key, fact.recognized_deployment_key
    assert_equal "default-agent-capabilities:v1", fact.agent_capabilities_version
  end

  test "projects queue-materialized tasks that carry the operation envelope" do
    conversation = create_conversation!
    graph = conversation.root_graph
    lane = conversation.chat_lane
    turn = graph.turns.create!(lane: lane, metadata: {})

    agent =
      create_agent_node!(
        graph: graph,
        lane_id: lane.id,
        turn_id: turn.id,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
      )

    row =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: graph,
        lane: lane,
        turn: turn,
        turn_id: turn.id,
        source_node: agent,
        source_hook_name: "agent_message_tool_loop",
        source_fingerprint: "direct-tool:tc_queue",
        logical_tool_name: "search",
        input: {
          "tool_call_id" => "tc_queue",
          "arguments" => {
            "query" => "TODO",
          },
        },
        authored_metadata: {
          "origin" => "direct_tool_loop",
          "reason" => "inspect repo state",
          "approval_hint" => {
            "mode" => "confirm",
          },
          "idempotency_key" => "direct.search.tc_queue",
          "sequence_id" => "opseq_fixture",
          "step_index" => 0,
          "step_count" => 1,
        },
        capability_registry_snapshot_id: "csnap_fixture",
        effective_tool_id: "etool_fixture",
        implementation_source: "agent",
        implementation_ref: "agent://search",
        execution_mode: "serial",
        queue_position: 10,
        status: "queued",
      )

    TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    task = graph.nodes.find(row.reload.materialized_task_node_id)
    task.mark_running!
    task.mark_finished!(
      payload: {
        "result" => AgentCore::Resources::Tools::ToolResult.success(text: "ok").to_h,
      },
    )

    fact = Statistics::ToolCallFactProjector.project!(task.reload)

    assert_equal "tc_queue", fact.tool_call_id
    assert_equal "search", fact.logical_tool_name
    assert_equal "search", fact.requested_name
    assert_equal "search", fact.resolved_name
    assert_equal "turn_internal_task_queue", fact.source
    assert_equal "csnap_fixture", fact.capability_registry_snapshot_id
    assert_equal "agent", fact.implementation_source
    assert_equal "agent://search", fact.implementation_ref
    assert_equal "success", fact.tool_outcome
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
