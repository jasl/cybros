require "test_helper"

class DAG::DBConstraintsTest < ActiveSupport::TestCase
  test "dag_nodes.state is constrained at the database layer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    assert_raises(ActiveRecord::StatementInvalid) do
      node.update_column(:state, "bogus")
    end
  end

  test "dag_edges.edge_type is constrained at the database layer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    from = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    to = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    edge = graph.edges.create!(from_node_id: from.id, to_node_id: to.id, edge_type: DAG::Edge::SEQUENCE)

    assert_raises(ActiveRecord::StatementInvalid) do
      edge.update_column(:edge_type, "bogus")
    end
  end

  test "dag_nodes.deleted_at is constrained to terminal nodes at the database layer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    assert_raises(ActiveRecord::StatementInvalid) do
      node.update_column(:deleted_at, Time.current)
    end
  end

  test "dag_node_visibility_patches enforces node graph_id at the database layer" do
    conversation_a = Conversation.create!
    graph_a = conversation_a.dag_graph

    conversation_b = Conversation.create!
    graph_b = conversation_b.dag_graph

    node_b = graph_b.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    assert_raises(ActiveRecord::InvalidForeignKey) do
      DAG::NodeVisibilityPatch.new(graph_id: graph_a.id, node_id: node_b.id).save!(validate: false)
    end
  end

  test "dag_nodes.retry_of_id is constrained to the same graph at the database layer" do
    conversation_a = Conversation.create!
    graph_a = conversation_a.dag_graph

    conversation_b = Conversation.create!
    graph_b = conversation_b.dag_graph

    node_a = graph_a.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    node_b = graph_b.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    assert_raises(ActiveRecord::InvalidForeignKey) do
      node_b.update_column(:retry_of_id, node_a.id)
    end
  end

  test "dag_nodes.compressed_by_id is constrained to the same graph at the database layer" do
    conversation_a = Conversation.create!
    graph_a = conversation_a.dag_graph

    conversation_b = Conversation.create!
    graph_b = conversation_b.dag_graph

    node_a = graph_a.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    node_b = graph_b.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    assert_raises(ActiveRecord::InvalidForeignKey) do
      node_b.update_columns(compressed_at: Time.current, compressed_by_id: node_a.id, updated_at: Time.current)
    end
  end

  test "dag_nodes compressed fields are constrained for consistency at the database layer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    other = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    assert_raises(ActiveRecord::StatementInvalid) do
      node.update_column(:compressed_at, Time.current)
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      node.update_column(:compressed_by_id, other.id)
    end
  end
end
