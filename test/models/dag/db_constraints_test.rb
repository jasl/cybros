require "test_helper"

class DAG::DBConstraintsTest < ActiveSupport::TestCase
  test "dag_nodes.state is constrained at the database layer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    assert_raises(ActiveRecord::StatementInvalid) do
      node.update_column(:state, "bogus")
    end
  end

  test "dag_edges.edge_type is constrained at the database layer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    from = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    to = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    edge = graph.edges.create!(from_node_id: from.id, to_node_id: to.id, edge_type: DAG::Edge::SEQUENCE)

    assert_raises(ActiveRecord::StatementInvalid) do
      edge.update_column(:edge_type, "bogus")
    end
  end

  test "dag_nodes.deleted_at is constrained to terminal nodes at the database layer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    assert_raises(ActiveRecord::StatementInvalid) do
      node.update_column(:deleted_at, Time.current)
    end
  end
end
