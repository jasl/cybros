require "test_helper"

class TurnInternalTasks::MaterializerTest < ActiveSupport::TestCase
  test "materialize_ready! materializes only the first serial row and backfills the task node" do
    conversation = create_conversation!(title: "Materializer serial")
    graph = conversation.dag_graph
    first = create_queue_row!(conversation:, queue_position: 10, execution_mode: "serial", source_fingerprint: "serial-10")
    second =
      create_queue_row!(
        conversation:,
        queue_position: 20,
        execution_mode: "parallel_safe",
        turn: first.turn,
        source_node: first.source_node,
        source_fingerprint: "serial-20",
      )

    materialized = TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    assert_equal [first.id], materialized.map(&:id)

    first.reload
    second.reload

    assert_equal "materialized", first.status
    assert first.materialized_task_node_id.present?
    assert_equal "queued", second.status

    task = graph.nodes.find(first.materialized_task_node_id)
    assert_equal Messages::Task.node_type_key, task.node_type
    assert_equal DAG::Node::PENDING, task.state
    assert_equal first.logical_tool_name, task.body_input.fetch("logical_tool_name")
    assert graph.edges.active.exists?(from_node_id: first.source_node_id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE)
  end

  test "materialize_ready! materializes a parallel-safe prefix and stops at the first serial barrier" do
    conversation = create_conversation!(title: "Materializer parallel prefix")
    graph = conversation.dag_graph
    first = create_queue_row!(conversation:, queue_position: 10, execution_mode: "parallel_safe", source_fingerprint: "parallel-10")
    second =
      create_queue_row!(
        conversation:,
        queue_position: 20,
        execution_mode: "parallel_safe",
        turn: first.turn,
        source_node: first.source_node,
        source_fingerprint: "parallel-20",
      )
    third =
      create_queue_row!(
        conversation:,
        queue_position: 30,
        execution_mode: "serial",
        turn: first.turn,
        source_node: first.source_node,
        source_fingerprint: "parallel-30",
      )

    materialized = TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    assert_equal [first.id, second.id], materialized.map(&:id)
    assert_equal "materialized", first.reload.status
    assert_equal "materialized", second.reload.status
    assert_equal "queued", third.reload.status
  end

  test "materialize_ready! splices an existing continuation behind a queued append task" do
    conversation = create_conversation!(title: "Materializer splice")
    graph = conversation.dag_graph
    row = create_queue_row!(conversation:, queue_position: 10, execution_mode: "serial")
    continuation =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::PENDING,
        lane: row.lane,
        turn: row.turn,
        metadata: {},
      )
    original_edge =
      graph.edges.create!(
        from_node_id: row.source_node_id,
        to_node_id: continuation.id,
        edge_type: DAG::Edge::SEQUENCE,
      )

    TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    row.reload
    task = graph.nodes.find(row.materialized_task_node_id)

    assert original_edge.reload.compressed_at.present?
    assert graph.edges.active.exists?(from_node_id: row.source_node_id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE)
    assert graph.edges.active.exists?(from_node_id: task.id, to_node_id: continuation.id, edge_type: DAG::Edge::SEQUENCE)
  end

  test "materialize_ready! keeps a shared continuation behind every task in a parallel-safe prefix" do
    conversation = create_conversation!(title: "Materializer parallel continuation")
    graph = conversation.dag_graph
    first = create_queue_row!(conversation:, queue_position: 10, execution_mode: "parallel_safe", source_fingerprint: "parallel-cont-10")
    second =
      create_queue_row!(
        conversation:,
        queue_position: 20,
        execution_mode: "parallel_safe",
        turn: first.turn,
        source_node: first.source_node,
        source_fingerprint: "parallel-cont-20",
      )
    continuation =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::PENDING,
        lane: first.lane,
        turn: first.turn,
        metadata: {},
      )
    original_edge =
      graph.edges.create!(
        from_node_id: first.source_node_id,
        to_node_id: continuation.id,
        edge_type: DAG::Edge::SEQUENCE,
      )

    TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    tasks = graph.nodes.where(id: [first.reload.materialized_task_node_id, second.reload.materialized_task_node_id]).order(:id).to_a

    assert_equal 2, tasks.size
    assert original_edge.reload.compressed_at.present?
    tasks.each do |task|
      assert graph.edges.active.exists?(from_node_id: first.source_node_id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE)
      assert graph.edges.active.exists?(from_node_id: task.id, to_node_id: continuation.id, edge_type: DAG::Edge::SEQUENCE)
    end
  end

  test "materialize_ready! treats serial barriers as turn-local rather than graph-global" do
    conversation = create_conversation!(title: "Materializer turn local barriers")
    graph = conversation.dag_graph

    turn_a = create_queue_row!(conversation:, queue_position: 10, execution_mode: "serial", source_fingerprint: "turn-a-10")
    create_queue_row!(
      conversation:,
      queue_position: 20,
      execution_mode: "serial",
      turn: turn_a.turn,
      source_node: turn_a.source_node,
      source_fingerprint: "turn-a-20",
    )
    turn_a.update!(status: "materialized")

    turn_b = create_queue_row!(conversation:, queue_position: 10, execution_mode: "serial", source_fingerprint: "turn-b-10")

    materialized = TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    assert_equal [turn_b.id], materialized.map(&:id)
    assert_equal "materialized", turn_b.reload.status
  end

  test "materialize_ready! rewinds later selected rows when an earlier row fails to materialize" do
    conversation = create_conversation!(title: "Materializer failed row rewind")
    graph = conversation.dag_graph
    first = create_queue_row!(conversation:, queue_position: 10, execution_mode: "parallel_safe", source_fingerprint: "failed-10")
    second =
      create_queue_row!(
        conversation:,
        queue_position: 20,
        execution_mode: "parallel_safe",
        turn: first.turn,
        source_node: first.source_node,
        source_fingerprint: "failed-20",
      )

    first.source_node.update!(compressed_at: Time.current, compressed_by_id: first.source_node.id)

    assert_raises(ActiveRecord::RecordInvalid) do
      TurnInternalTasks::Materializer.materialize_ready!(graph: graph)
    end

    assert_equal "failed_materialization", first.reload.status
    assert_equal "queued", second.reload.status
    assert_nil second.materialized_task_node_id
  end

  test "materialize_ready! does not resurrect a row canceled before it acquires the graph lock" do
    conversation = create_conversation!(title: "Materializer canceled row")
    graph = conversation.dag_graph
    row = create_queue_row!(conversation:, queue_position: 10, execution_mode: "serial", source_fingerprint: "canceled-before-lock")
    row.update!(status: "materializing")
    row.update!(status: "canceled", canceled_reason: "turn_reset")

    TurnInternalTasks::Materializer.new(graph: graph).send(:materialize_row!, row)

    queued_tasks =
      graph.nodes.active.where(node_type: Messages::Task.node_type_key).where(
        "metadata ->> 'generated_by' = ?",
        "turn_internal_task_queue",
      )

    assert_equal "canceled", row.reload.status
    assert_nil row.materialized_task_node_id
    assert_empty queued_tasks
  end

  test "materialize_ready! projects the operation envelope into the materialized task" do
    conversation = create_conversation!(title: "Materializer operation envelope")
    graph = conversation.dag_graph
    row =
      create_queue_row!(
        conversation: conversation,
        queue_position: 10,
        execution_mode: "serial",
        source_fingerprint: "envelope-10",
        source_hook_name: "agent_message_tool_loop",
        logical_tool_name: "search",
        input: {
          "tool_call_id" => "tc_env",
          "arguments" => {
            "query" => "TODO",
          },
        },
        authored_metadata: {
          "origin" => "bootstrap_proposal",
          "reason" => "inspect repo state",
          "approval_hint" => {
            "mode" => "confirm",
          },
          "idempotency_key" => "bootstrap.search",
          "sequence_id" => "opseq_fixture",
          "step_index" => 0,
          "step_count" => 2,
        },
      )

    TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    task = graph.nodes.find(row.reload.materialized_task_node_id)

    assert_equal "tc_env", task.body_input.fetch("tool_call_id")
    assert_equal "search", task.body_input.fetch("logical_tool_name")
    assert_equal({ "query" => "TODO" }, task.body_input.fetch("arguments"))
    assert_equal "inspect repo state", task.body_input.fetch("reason")
    assert_equal "bootstrap_proposal", task.body_input.fetch("origin")
    assert_equal({ "mode" => "confirm" }, task.body_input.fetch("approval_hint"))
    assert_equal "bootstrap.search", task.body_input.fetch("idempotency_key")
    assert_equal "opseq_fixture", task.body_input.fetch("sequence_id")
    assert_equal 0, task.body_input.fetch("step_index")
    assert_equal 2, task.body_input.fetch("step_count")
    assert_equal "bootstrap_proposal", task.metadata.dig("authored_metadata", "origin")
  end

  test "materialize_ready! restores direct-tool task source and metadata when provided" do
    conversation = create_conversation!(title: "Materializer direct tool metadata")
    graph = conversation.dag_graph
    row =
      create_queue_row!(
        conversation: conversation,
        queue_position: 10,
        execution_mode: "serial",
        source_fingerprint: "direct-tool-metadata-10",
        source_hook_name: "agent_message_tool_loop",
        logical_tool_name: "compact_context",
        input: {
          "tool_call_id" => "tc_compact",
          "requested_name" => "compact_context",
          "source" => "model_choice",
          "arguments" => {
            "reason" => "soft_limit_reached",
          },
        },
        authored_metadata: {
          "reason" => "llm_tool_call",
          "origin" => "agent_message_tool_loop",
          "task_metadata" => {
            "generated_by" => "agent_core",
            "source" => "model_choice",
            "context_budget" => {
              "budget_state" => "soft_limit_reached",
              "budget_action" => "advise_compact",
              "budget_fingerprint" => "fp_123",
            },
          },
        },
      )

    TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    task = graph.nodes.find(row.reload.materialized_task_node_id)

    assert_equal "model_choice", task.body_input.fetch("source")
    assert_equal "agent_core", task.metadata.fetch("generated_by")
    assert_equal "model_choice", task.metadata.fetch("source")
    assert_equal "soft_limit_reached", task.metadata.dig("context_budget", "budget_state")
    assert_equal "advise_compact", task.metadata.dig("context_budget", "budget_action")
    assert_equal "fp_123", task.metadata.dig("context_budget", "budget_fingerprint")
  end

  test "materialize_ready! emits planned and waiting activity events for approval-gated direct tools" do
    conversation = create_conversation!(title: "Materializer direct tool activity")
    graph = conversation.dag_graph
    turn = graph.turns.create!(lane: conversation.chat_lane, metadata: {})
    source_node =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane: conversation.chat_lane,
        turn: turn,
        metadata: {
          "turn_execution" => {
            "diagnostic_level" => "debug",
          },
        },
      )
    row =
      create_queue_row!(
        conversation: conversation,
        queue_position: 10,
        execution_mode: "serial",
        turn: turn,
        source_node: source_node,
        source_fingerprint: "direct-tool-activity-10",
        source_hook_name: "agent_message_tool_loop",
        logical_tool_name: "danger",
        input: {
          "tool_call_id" => "tc_wait",
          "requested_name" => "danger",
          "arguments" => {},
          "source" => "agent",
        },
        authored_metadata: {
          "origin" => "agent_message_tool_loop",
          "reason" => "llm_tool_call",
          "approval" => {
            "required" => true,
            "deny_effect" => "block",
            "reason" => "danger_requires_review",
          },
        },
      )

    TurnInternalTasks::Materializer.materialize_ready!(graph: graph)

    task = graph.nodes.find(row.reload.materialized_task_node_id)
    events = graph.node_event_page_for(task.id, limit: 10, kinds: DAG::NodeEvent::ACTIVITY_EVENT_KINDS)

    assert_equal [DAG::NodeEvent::ACTIVITY_PLANNED, DAG::NodeEvent::ACTIVITY_WAITING], events.map { |event| event.fetch("kind") }
    assert_equal %w[planned awaiting_approval], events.map { |event| event.fetch("payload").fetch("status") }
    assert_equal ["planning", "authorization"], events.map { |event| event.fetch("payload").fetch("phase") }
    assert_equal %w[debug debug], events.map { |event| event.fetch("payload").fetch("diagnostic_level") }
    assert_equal true, events.last.fetch("payload").dig("data", "required")
    assert_equal "block", events.last.fetch("payload").dig("data", "deny_effect")
  end

  test "summarize_arguments falls back cleanly for non-serializable argument payloads" do
    conversation = create_conversation!(title: "Materializer summarize arguments")
    materializer = TurnInternalTasks::Materializer.new(graph: conversation.dag_graph)
    arguments = {}
    arguments["self"] = arguments

    summary = materializer.send(:summarize_arguments, arguments)

    assert_equal "", summary
  end

  private

    def create_queue_row!(conversation:, queue_position:, execution_mode:, turn: nil, source_node: nil, source_fingerprint: nil, source_hook_name: "after_task_notice", logical_tool_name: "subagent_spawn", input: nil, authored_metadata: nil)
      graph = conversation.dag_graph
      lane = conversation.chat_lane
      turn ||= graph.turns.create!(lane: lane, metadata: {})
      source_node ||=
        graph.nodes.create!(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane: lane,
          turn: turn,
          metadata: {},
        )

      TurnInternalTask.create!(
        conversation: conversation,
        graph: graph,
        lane: lane,
        turn: turn,
        source_node: source_node,
        source_hook_name: source_hook_name,
        source_fingerprint: source_fingerprint || "notice-#{queue_position}",
        logical_tool_name: logical_tool_name,
        input: input || { "name" => "worker-#{queue_position}" },
        authored_metadata: authored_metadata || { "source" => "test" },
        execution_mode: execution_mode,
        queue_position: queue_position,
        status: "queued",
      )
    end
end
