require "test_helper"

class DAG::GraphSurgeryAndVisibilityFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FixedExecutor
    def initialize(payload)
      @payload = payload
    end

    def execute(node:, context:)
      _ = node
      _ = context

      DAG::ExecutionResult.finished(payload: @payload, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "graph surgery: deferred visibility changes, compression, edit replacement, and retry replacement keep graph correct" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c030"

    system = nil
    developer = nil
    user = nil
    agent_1 = nil
    task = nil
    agent_2 = nil

    graph.mutate!(turn_id: turn_id) do |m|
      system = m.create_node(node_type: DAG::Node::SYSTEM_MESSAGE, state: DAG::Node::FINISHED, content: "sys", metadata: {})
      developer = m.create_node(node_type: DAG::Node::DEVELOPER_MESSAGE, state: DAG::Node::FINISHED, content: "dev", metadata: {})
      user = m.create_node(node_type: DAG::Node::USER_MESSAGE, state: DAG::Node::FINISHED, content: "u1", metadata: {})
      agent_1 = m.create_node(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::FINISHED, metadata: { "transcript_visible" => true })
      task = m.create_node(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, body_input: { "name" => "t" }, metadata: {})
      agent_2 = m.create_node(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

      m.create_edge(from_node: system, to_node: developer, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: developer, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: agent_1, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: agent_1, to_node: task, edge_type: DAG::Edge::DEPENDENCY)
      m.create_edge(from_node: task, to_node: agent_2, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_equal :deferred, system.request_exclude_from_context!
    assert_nil system.reload.context_excluded_at
    assert DAG::NodeVisibilityPatch.exists?(graph_id: graph.id, node_id: system.id)

    assert_equal :deferred, developer.request_soft_delete!
    assert_nil developer.reload.deleted_at
    assert DAG::NodeVisibilityPatch.exists?(graph_id: graph.id, node_id: developer.id)

    assert task.mark_finished!(content: "ok")

    graph.with_graph_lock! do
      applied = graph.apply_visibility_patches_if_idle!
      assert_equal 2, applied
    end

    assert system.reload.context_excluded_at.present?
    assert developer.reload.deleted_at.present?
    assert_not DAG::NodeVisibilityPatch.exists?(graph_id: graph.id, node_id: system.id)
    assert_not DAG::NodeVisibilityPatch.exists?(graph_id: graph.id, node_id: developer.id)

    context = graph.context_for(agent_2.id)
    context_ids = context.map { |node| node.fetch("node_id") }
    refute_includes context_ids, system.id
    refute_includes context_ids, developer.id
    assert_includes context_ids, user.id

    summary = graph.compress!(node_ids: [agent_1.id, task.id], summary_content: "compressed")

    context = graph.context_for(agent_2.id)
    context_ids = context.map { |node| node.fetch("node_id") }
    assert_includes context_ids, summary.id
    refute_includes context_ids, agent_1.id
    refute_includes context_ids, task.id

    registry = DAG::ExecutorRegistry.new
    registry.register(DAG::Node::AGENT_MESSAGE, FixedExecutor.new({ "content" => "a2" }))
    registry.register(DAG::Node::TASK, FixedExecutor.new({ "result" => "ok" }))

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      DAG::Runner.run_node!(agent_2.id)
    ensure
      DAG.executor_registry = original_registry
    end

    assert_equal DAG::Node::FINISHED, agent_2.reload.state

    edited_user = user.reload.edit!(new_input: { "content" => "u2" })
    assert_equal "u2", edited_user.body_input["content"]

    leaf = graph.leaf_nodes.sole
    assert_equal DAG::Node::AGENT_MESSAGE, leaf.node_type
    assert_equal DAG::Node::PENDING, leaf.state

    parent = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    original = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    downstream = graph.nodes.create!(node_type: DAG::Node::CHARACTER_MESSAGE, state: DAG::Node::PENDING, metadata: { "actor" => "npc" })
    graph.edges.create!(from_node_id: parent.id, to_node_id: original.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    replaced = original.retry!
    assert_equal DAG::Node::PENDING, replaced.state
    assert graph.edges.active.exists?(from_node_id: replaced.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end
end
