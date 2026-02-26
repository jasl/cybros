require "test_helper"

class DAG::AgentToolCallsFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class PlanningAndFinalAgentExecutor
    def execute(node:, context:, stream:)
      _ = stream
      phase = node.metadata["phase"].to_s

      if phase == "plan"
        create_tool_calls_and_join_message(node)
        DAG::ExecutionResult.finished(payload: {}, usage: { "total_tokens" => 2 })
      else
        task_names = context.filter_map { |n| n.dig("payload", "input", "name") }.map(&:to_s).reject(&:blank?).sort
        task_previews = context.filter_map { |n| n.dig("payload", "output_preview", "result") }.map(&:to_s).reject(&:blank?)

        content = +"Final answer"
        content << " (tasks=#{task_names.join(",")})" if task_names.any?
        content << "\n" << task_previews.join("\n") if task_previews.any?

        DAG::ExecutionResult.finished(payload: { "content" => content }, usage: { "total_tokens" => 3 })
      end
    end

    private

    def create_tool_calls_and_join_message(node)
      graph = node.graph

      graph.mutate!(turn_id: node.turn_id) do |m|
        hash_task = m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          idempotency_key: "hash_task",
          body_input: { "name" => "hash_task" },
          metadata: {}
        )
        array_task = m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          idempotency_key: "array_task",
          body_input: { "name" => "array_task" },
          metadata: {}
        )
        final = m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          idempotency_key: "final_answer",
          metadata: { "phase" => "final" }
        )

        m.create_edge(from_node: node, to_node: hash_task, edge_type: DAG::Edge::SEQUENCE)
        m.create_edge(from_node: node, to_node: array_task, edge_type: DAG::Edge::SEQUENCE)

        m.create_edge(from_node: hash_task, to_node: final, edge_type: DAG::Edge::DEPENDENCY)
        m.create_edge(from_node: array_task, to_node: final, edge_type: DAG::Edge::DEPENDENCY)
      end
    end
  end

  class ToolCallExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      name = node.body_input["name"].to_s

      result =
        case name
        when "hash_task"
          { "a" => 1, "b" => 2 }
        when "array_task"
          [1, 2, 3]
        else
          name
        end

      DAG::ExecutionResult.finished(payload: { "result" => result }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "agent flow: plan -> parallel tool calls -> join -> final transcript" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c010"

    user = nil
    planner = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Write code", metadata: {})
      planner = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "phase" => "plan" })
      m.create_edge(from_node: user, to_node: planner, edge_type: DAG::Edge::SEQUENCE)
    end

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, ToolCallExecutor.new)
    registry.register(Messages::AgentMessage.node_type_key, PlanningAndFinalAgentExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [planner.id], claimed.map(&:id)
      DAG::Runner.run_node!(planner.id)

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 2, tasks.length

      final = graph.nodes.active.find_by!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "phase" => "final" })

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal tasks.map(&:id), claimed.map(&:id)
      tasks.each { |task| DAG::Runner.run_node!(task.id) }

      hash_task = tasks.find { |task| task.body_input["name"] == "hash_task" }
      array_task = tasks.find { |task| task.body_input["name"] == "array_task" }

      assert_equal "hash", hash_task.reload.metadata.dig("output_stats", "result_type")
      assert_equal 2, hash_task.metadata.dig("output_stats", "result_key_count")
      assert_equal "array", array_task.reload.metadata.dig("output_stats", "result_type")
      assert_equal 3, array_task.metadata.dig("output_stats", "result_array_len")

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [final.id], claimed.map(&:id)
      DAG::Runner.run_node!(final.id)

      transcript = graph.transcript_for(final.id)
      assert_equal [user.id, final.id], transcript.map { |node| node.fetch("node_id") }

      context = graph.context_for(final.id)
      context_ids = context.map { |node| node.fetch("node_id") }
      [user.id, planner.id, hash_task.id, array_task.id, final.id].each do |node_id|
        assert_includes context_ids, node_id
      end

      included_ids = context_ids.index_with { |node_id| context_ids.index(node_id) }

      graph.edges.active.where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES).each do |edge|
        next unless included_ids.key?(edge.from_node_id) && included_ids.key?(edge.to_node_id)

        assert_operator included_ids.fetch(edge.from_node_id), :<, included_ids.fetch(edge.to_node_id)
      end

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end

  test "tool failure propagation makes skipped message transcript-visible with a safe preview" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c011"

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_input: { "content" => "Do the thing" },
      metadata: {}
    )
    task = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, turn_id: turn_id, metadata: { "error" => "boom" })
    character = graph.nodes.create!(node_type: Messages::CharacterMessage.node_type_key, state: DAG::Node::PENDING, turn_id: turn_id, metadata: { "actor" => "npc" })

    graph.edges.create!(from_node_id: user.id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: task.id, to_node_id: character.id, edge_type: DAG::Edge::DEPENDENCY)

    DAG::FailurePropagation.propagate!(graph: graph)

    character.reload
    assert_equal DAG::Node::SKIPPED, character.state
    assert_equal "blocked_by_failed_dependencies", character.metadata["reason"]

    transcript = graph.transcript_for(character.id)
    assert_equal [Messages::UserMessage.node_type_key, Messages::CharacterMessage.node_type_key], transcript.map { |node| node.fetch("node_type") }

    preview = transcript.last.dig("payload", "output_preview", "content").to_s
    assert_includes preview, "Skipped:"
    assert_includes preview, "blocked by failed dependencies"

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end
end
