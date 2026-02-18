require "test_helper"

class DAG::FailurePropagationTest < ActiveSupport::TestCase
  test "propagate! skips nodes blocked by failed dependencies and cascades" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    b = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    c = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

    e1 = graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::DEPENDENCY)
    e2 = graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)

    DAG::FailurePropagation.propagate!(graph: graph)

    assert_equal DAG::Node::SKIPPED, b.reload.state
    assert_equal "blocked_by_failed_dependencies", b.metadata["reason"]
    blocked_by_b = b.metadata.fetch("blocked_by")
    assert_equal 1, blocked_by_b.length
    assert_equal a.id, blocked_by_b.first.fetch("node_id")
    assert_equal DAG::Node::ERRORED, blocked_by_b.first.fetch("state")
    assert_equal e1.id, blocked_by_b.first.fetch("edge_id")

    assert_equal DAG::Node::SKIPPED, c.reload.state
    assert_equal "blocked_by_failed_dependencies", c.metadata["reason"]
    blocked_by_c = c.metadata.fetch("blocked_by")
    assert_equal 1, blocked_by_c.length
    assert_equal b.id, blocked_by_c.first.fetch("node_id")
    assert_equal DAG::Node::SKIPPED, blocked_by_c.first.fetch("state")
    assert_equal e2.id, blocked_by_c.first.fetch("edge_id")

    assert conversation.events.exists?(event_type: "node_state_changed", subject: b)
    assert conversation.events.exists?(event_type: "node_state_changed", subject: c)
  end

  test "propagate! does not skip nodes whose dependency parents are pending" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    child = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    DAG::FailurePropagation.propagate!(graph: graph)

    assert_equal DAG::Node::PENDING, child.reload.state
  end

  test "propagate! ignores dirty dependency edges whose parents belong to another graph" do
    conversation_a = Conversation.create!
    graph_a = conversation_a.dag_graph

    conversation_b = Conversation.create!
    graph_b = conversation_b.dag_graph

    dirty_parent = graph_b.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    child = graph_a.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    DAG::Edge.new(
      graph_id: graph_a.id,
      from_node_id: dirty_parent.id,
      to_node_id: child.id,
      edge_type: DAG::Edge::DEPENDENCY,
      metadata: {}
    ).save!(validate: false)

    DAG::FailurePropagation.propagate!(graph: graph_a)

    assert_equal DAG::Node::PENDING, child.reload.state
  end
end
