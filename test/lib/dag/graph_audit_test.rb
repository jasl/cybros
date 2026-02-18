require "test_helper"

class DAG::GraphAuditTest < ActiveSupport::TestCase
  test "scan detects and repair! compresses active edges pointing at inactive nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    b = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    edge = graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)

    b.update_columns(compressed_at: Time.current, compressed_by_id: a.id, updated_at: Time.current)

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["type"] == DAG::GraphAudit::ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE])
    assert edge.reload.compressed_at.present?
  end

  test "repair! deletes visibility patches for inactive nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    patch = DAG::NodeVisibilityPatch.create!(graph: graph, node: node, context_excluded_at: Time.current)

    node.update_columns(compressed_at: Time.current, compressed_by_id: node.id, updated_at: Time.current)

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["subject_id"] == patch.id && i["type"] == DAG::GraphAudit::ISSUE_STALE_VISIBILITY_PATCH }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_STALE_VISIBILITY_PATCH])
    assert_not DAG::NodeVisibilityPatch.exists?(id: patch.id)
  end

  test "repair! fixes leaf invariant violations by calling validate_leaf_invariant!" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["type"] == DAG::GraphAudit::ISSUE_LEAF_INVARIANT_VIOLATION }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_LEAF_INVARIANT_VIOLATION])
    assert graph.nodes.active.exists?(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
  end

  test "repair! reclaims stale running nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::RUNNING,
      lease_expires_at: 1.minute.ago,
      metadata: {}
    )

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["subject_id"] == node.id && i["type"] == DAG::GraphAudit::ISSUE_STALE_RUNNING_NODE }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_STALE_RUNNING_NODE])
    assert_equal DAG::Node::ERRORED, node.reload.state
    assert_equal "running_lease_expired", node.metadata.fetch("error")
  end
end
