require "test_helper"

class ConversationDAGTest < ActiveSupport::TestCase
  test "mutate! repairs leaf invariant by appending a pending agent_message" do
    conversation = Conversation.create!

    conversation.mutate! do |m|
      m.create_node(
        node_type: DAG::Node::USER_MESSAGE,
        state: DAG::Node::FINISHED,
        content: "Hello"
      )
    end

    leaves = conversation.leaf_nodes.to_a
    assert_equal 1, leaves.length

    leaf = leaves.first
    assert_equal DAG::Node::AGENT_MESSAGE, leaf.node_type
    assert_equal DAG::Node::PENDING, leaf.state

    user_message = conversation.dag_nodes.find_by!(node_type: DAG::Node::USER_MESSAGE)
    assert conversation.dag_edges.active.exists?(
      from_node_id: user_message.id,
      to_node_id: leaf.id,
      edge_type: DAG::Edge::SEQUENCE
    )
  end

    test "context_for returns a topological ordering for a join node" do
    conversation = Conversation.create!

    task_a = conversation.dag_nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::FINISHED,
      metadata: { "name" => "a" }
    )
    task_b = conversation.dag_nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::FINISHED,
      metadata: { "name" => "b" }
    )
    agent = conversation.dag_nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::PENDING,
      metadata: {}
    )

    conversation.dag_edges.create!(from_node_id: task_a.id, to_node_id: agent.id, edge_type: DAG::Edge::DEPENDENCY)
    conversation.dag_edges.create!(from_node_id: task_b.id, to_node_id: agent.id, edge_type: DAG::Edge::DEPENDENCY)

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

      root = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
      forked = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
      conversation.dag_edges.create!(
        from_node_id: root.id,
        to_node_id: forked.id,
        edge_type: DAG::Edge::BRANCH,
        metadata: { "branch_kinds" => ["fork"] }
      )

      context = conversation.context_for(forked.id)
      ids = context.map { |node| node.fetch("node_id") }

      assert_includes ids, forked.id
      refute_includes ids, root.id

      actual_fork = root.fork!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING)
      fork_context = conversation.context_for(actual_fork.id)
      fork_ids = fork_context.map { |node| node.fetch("node_id") }

      assert_includes fork_ids, root.id
      assert_includes fork_ids, actual_fork.id
    end

  test "context_for substitutes summary nodes for compressed subgraphs" do
    conversation = Conversation.create!

      a = conversation.dag_nodes.create!(
        node_type: DAG::Node::USER_MESSAGE,
        state: DAG::Node::FINISHED,
        payload_input: { "content" => "hi" },
        metadata: {}
      )
      b = conversation.dag_nodes.create!(
        node_type: DAG::Node::AGENT_MESSAGE,
        state: DAG::Node::FINISHED,
        payload_output: { "content" => "hello" },
        metadata: {}
      )
    c = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: { "name" => "task" })
    d = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})

    conversation.dag_edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    conversation.dag_edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)
    conversation.dag_edges.create!(from_node_id: c.id, to_node_id: d.id, edge_type: DAG::Edge::SEQUENCE)

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

  test "leaf_nodes ignores blocking edges that point to inactive nodes" do
    conversation = Conversation.create!

    a = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    b = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    conversation.dag_edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)

    refute_includes conversation.leaf_nodes.pluck(:id), a.id

    b.update!(compressed_at: Time.current)

    assert_includes conversation.leaf_nodes.pluck(:id), a.id
  end
end
