require "test_helper"

class DAG::IdempotencyTest < ActiveSupport::TestCase
  test "create_node is idempotent within graph+turn+node_type" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000000"

    node_1 = nil
    node_2 = nil

    graph.mutate!(turn_id: turn_id) do |m|
      node_1 = m.create_node(
        node_type: DAG::Node::TASK,
        state: DAG::Node::PENDING,
        idempotency_key: "k1",
        body_input: { "name" => "t1" },
        metadata: {}
      )

      node_2 = m.create_node(
        node_type: DAG::Node::TASK,
        state: DAG::Node::PENDING,
        idempotency_key: "k1",
        body_input: { "name" => "t1" },
        metadata: {}
      )
    end

    assert_equal node_1.id, node_2.id
    assert_equal 1, graph.nodes.count
    assert_equal 1, DAG::NodeBody.count
  end

  test "create_node raises when idempotency_key collides with different body I/O" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000001"

    graph.mutate!(turn_id: turn_id) do |m|
      m.create_node(
        node_type: DAG::Node::TASK,
        state: DAG::Node::PENDING,
        idempotency_key: "k1",
        body_input: { "name" => "t1" },
        metadata: {}
      )
    end

    assert_raises(ArgumentError) do
      graph.mutate!(turn_id: turn_id) do |m|
        m.create_node(
          node_type: DAG::Node::TASK,
          state: DAG::Node::PENDING,
          idempotency_key: "k1",
          body_input: { "name" => "DIFFERENT" },
          metadata: {}
        )
      end
    end

    assert_equal 1, graph.nodes.count
  end

  test "create_edge is idempotent for the same endpoints" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000002"

    a = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {}, turn_id: turn_id)
    b = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {}, turn_id: turn_id)

    edge_1 = nil
    edge_2 = nil

    graph.mutate! do |m|
      edge_1 = m.create_edge(from_node: a, to_node: b, edge_type: DAG::Edge::SEQUENCE)
      edge_2 = m.create_edge(from_node: a, to_node: b, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_equal edge_1.id, edge_2.id
    assert_equal 1, graph.edges.count
  end
end
