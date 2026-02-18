require "test_helper"

class ConversationDAGTest < ActiveSupport::TestCase
  test "conversation automatically builds and persists a dag_graph" do
    conversation = Conversation.create!

    assert conversation.dag_graph.present?
    assert conversation.dag_graph.persisted?
    assert_equal conversation, conversation.dag_graph.attachable
  end

  test "mutate! repairs leaf invariant by appending a pending agent_message" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    conversation.mutate! do |m|
      m.create_node(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        content: "Hello"
      )
    end

    leaves = graph.leaf_nodes.to_a
    assert_equal 1, leaves.length

    leaf = leaves.first
    assert_equal Messages::AgentMessage.node_type_key, leaf.node_type
    assert_equal DAG::Node::PENDING, leaf.state

    user_message = graph.nodes.find_by!(node_type: Messages::UserMessage.node_type_key)
    assert_equal user_message.turn_id, leaf.turn_id
    assert graph.edges.active.exists?(
      from_node_id: user_message.id,
      to_node_id: leaf.id,
      edge_type: DAG::Edge::SEQUENCE
    )
  end

  test "context_for returns a topological ordering for a join node" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    task_a = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      metadata: { "name" => "a" }
    )
    task_b = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      metadata: { "name" => "b" }
    )
    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      metadata: {}
    )

    graph.edges.create!(from_node_id: task_a.id, to_node_id: agent.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: task_b.id, to_node_id: agent.id, edge_type: DAG::Edge::DEPENDENCY)

    context = conversation.context_for(agent.id)
    ids = context.map { |node| node.fetch("node_id") }

    assert_includes ids, task_a.id
    assert_includes ids, task_b.id
    assert_includes ids, agent.id

    assert_operator ids.index(task_a.id), :<, ids.index(agent.id)
    assert_operator ids.index(task_b.id), :<, ids.index(agent.id)
  end

  test "context_for ignores branch edges and relies on causal edges" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    root = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    forked = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(
      from_node_id: root.id,
      to_node_id: forked.id,
      edge_type: DAG::Edge::BRANCH,
      metadata: { "branch_kinds" => ["fork"] }
    )

    context = conversation.context_for(forked.id)
    ids = context.map { |node| node.fetch("node_id") }

    assert_includes ids, forked.id
    refute_includes ids, root.id

    actual_fork = root.fork!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
    refute_equal root.turn_id, actual_fork.turn_id

    assert_equal DAG::Lane::BRANCH, actual_fork.lane.role
    assert_equal graph.main_lane.id, actual_fork.lane.parent_lane_id
    assert_equal root.id, actual_fork.lane.forked_from_node_id
    assert_equal actual_fork.id, actual_fork.lane.root_node_id

    fork_context = conversation.context_for(actual_fork.id)
    fork_ids = fork_context.map { |node| node.fetch("node_id") }

    assert_includes fork_ids, root.id
    assert_includes fork_ids, actual_fork.id
  end

  test "context_for substitutes summary nodes for compressed subgraphs" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    b = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )
    c = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: { "name" => "task" })
    d = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

    graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: c.id, to_node_id: d.id, edge_type: DAG::Edge::SEQUENCE)

    summary = conversation.compress!(node_ids: [b.id, c.id], summary_content: "summary")

    context = conversation.context_for(d.id)
    ids = context.map { |node| node.fetch("node_id") }

    assert_includes ids, a.id
    assert_includes ids, summary.id
    assert_includes ids, d.id

    refute_includes ids, b.id
    refute_includes ids, c.id

    assert_operator ids.index(a.id), :<, ids.index(summary.id)
    assert_operator ids.index(summary.id), :<, ids.index(d.id)
  end

  test "context_for does not traverse through inactive nodes even if edges remain active" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    x = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    y = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    z = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

    graph.edges.create!(from_node_id: x.id, to_node_id: y.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: y.id, to_node_id: z.id, edge_type: DAG::Edge::SEQUENCE)

    y.update!(compressed_at: Time.current, compressed_by_id: x.id)

    context = conversation.context_for(z.id)
    ids = context.map { |node| node.fetch("node_id") }

    assert_equal [z.id], ids
  end

  test "leaf_nodes ignores blocking edges that point to inactive nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    b = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)

    refute_includes graph.leaf_nodes.pluck(:id), a.id

    b.update!(compressed_at: Time.current, compressed_by_id: a.id)

    assert_includes graph.leaf_nodes.pluck(:id), a.id
  end
end
