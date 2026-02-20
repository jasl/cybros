require "test_helper"

class DAG::SubgraphTest < ActiveSupport::TestCase
  test "graph automatically has a unique main subgraph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    assert_equal 1, graph.subgraphs.where(role: DAG::Subgraph::MAIN).count
    assert_equal graph.subgraphs.find_by!(role: DAG::Subgraph::MAIN), graph.main_subgraph

    assert_raises(ActiveRecord::RecordNotUnique) do
      graph.subgraphs.create!(role: DAG::Subgraph::MAIN, metadata: {})
    end
  end

  test "subgraph relationship pointers must not cross graphs" do
    conversation_a = Conversation.create!
    graph_a = conversation_a.dag_graph
    subgraph_a = graph_a.main_subgraph

    conversation_b = Conversation.create!
    graph_b = conversation_b.dag_graph

    assert_raises(ActiveRecord::RecordInvalid) do
      graph_b.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: subgraph_a.id, metadata: {})
    end
  end

  test "root_node_id must belong to the subgraph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    subgraph_a = graph.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: main_subgraph.id, metadata: {})
    subgraph_b = graph.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: main_subgraph.id, metadata: {})

    node_in_a =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        subgraph_id: subgraph_a.id,
        metadata: {}
      )

    assert_raises(ActiveRecord::RecordInvalid) do
      subgraph_b.update!(root_node_id: node_in_a.id)
    end
  end

  test "nodes default to graph.main_subgraph for both direct creates and mutation creates" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    direct = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    assert_equal main_subgraph.id, direct.subgraph_id

    via_mutation = nil
    graph.mutate! do |m|
      via_mutation = m.create_node(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    end
    assert_equal main_subgraph.id, via_mutation.subgraph_id
  end

  test "create_node inherits subgraph_id from existing nodes in the same turn" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    subgraph = graph.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: main_subgraph.id, metadata: {})
    turn_id = "0194f3c0-0000-7000-8000-00000000d001"

    anchor = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      subgraph_id: subgraph.id,
      turn_id: turn_id,
      metadata: {}
    )

    created = nil
    graph.mutate!(turn_id: turn_id) do |m|
      created = m.create_node(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    end

    assert_equal anchor.subgraph_id, created.subgraph_id
  end

  test "fork creates a new branch subgraph and leaf repair stays within that subgraph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    from = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )
    assert_equal main_subgraph.id, from.subgraph_id

    forked_user =
      from.fork!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        body_input: { "content" => "branch" },
        metadata: {}
      )

    subgraph = forked_user.subgraph
    assert_equal DAG::Subgraph::BRANCH, subgraph.role
    assert_equal main_subgraph.id, subgraph.parent_subgraph_id
    assert_equal from.id, subgraph.forked_from_node_id
    assert_equal forked_user.id, subgraph.root_node_id

    repaired = graph.nodes.active.find_by!(
      subgraph_id: subgraph.id,
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      metadata: { "generated_by" => "leaf_invariant" }
    )
    assert_equal forked_user.turn_id, repaired.turn_id
  end

  test "archived subgraphs block new turns but allow existing turns" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    subgraph = graph.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: main_subgraph.id, metadata: {})
    turn_id = "0194f3c0-0000-7000-8000-00000000d002"

    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      subgraph_id: subgraph.id,
      turn_id: turn_id,
      metadata: {}
    )

    subgraph.update!(archived_at: Time.current)

    continued =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        subgraph_id: subgraph.id,
        turn_id: turn_id,
        metadata: {}
      )
    assert_equal subgraph.id, continued.subgraph_id
    assert_equal turn_id, continued.turn_id

    error =
      assert_raises(ActiveRecord::RecordInvalid) do
        graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, subgraph_id: subgraph.id, metadata: {})
      end
    assert_match(/Subgraph is archived/, error.message)
  end

  test "archive_subgraph! mode cancel stops running and pending without creating new pending work" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    subgraph = graph.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: main_subgraph.id, metadata: {})

    running = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, subgraph_id: subgraph.id, metadata: {})
    pending = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, subgraph_id: subgraph.id, metadata: {})

    graph.mutate! do |m|
      m.archive_subgraph!(subgraph: subgraph, mode: :cancel, at: Time.current, reason: "stopped_by_user")
    end

    state_events =
      conversation.events
        .where(event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED)
        .pluck(:subject_id, :particulars)
        .to_h
    assert_equal({ "from" => "running", "to" => "stopped" }, state_events.fetch(running.id))
    assert_equal({ "from" => "pending", "to" => "stopped" }, state_events.fetch(pending.id))

    subgraph.reload
    assert subgraph.archived_at.present?

    assert_equal DAG::Node::STOPPED, running.reload.state
    assert_equal "stopped_by_user", running.metadata["reason"]
    assert running.finished_at.present?

    assert_equal DAG::Node::STOPPED, pending.reload.state
    assert_equal "stopped_by_user", pending.metadata["reason"]
    assert pending.finished_at.present?

    assert graph.nodes.active.where(subgraph_id: subgraph.id, state: DAG::Node::PENDING).none?
    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end

  test "merge creates a pending join node in the target subgraph without archiving the source subgraphs" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    main_head = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_equal main_subgraph.id, main_head.subgraph_id

    source_subgraph = graph.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: main_subgraph.id, metadata: {})
    source_head = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      subgraph_id: source_subgraph.id,
      metadata: {}
    )

    merge_node = nil
    graph.mutate! do |m|
      merge_node =
        m.merge_subgraphs!(
          target_subgraph: main_subgraph,
          target_from_node: main_head,
          source_subgraphs_and_nodes: [{ subgraph: source_subgraph, from_node: source_head }],
          node_type: Messages::AgentMessage.node_type_key,
          metadata: { "kind" => "test" }
        )
    end

    assert_equal main_subgraph.id, merge_node.subgraph_id
    assert_equal DAG::Node::PENDING, merge_node.state

    assert graph.edges.active.exists?(
      from_node_id: main_head.id,
      to_node_id: merge_node.id,
      edge_type: DAG::Edge::SEQUENCE,
      metadata: { "generated_by" => "merge" }
    )

    dependency = graph.edges.active.find_by!(
      from_node_id: source_head.id,
      to_node_id: merge_node.id,
      edge_type: DAG::Edge::DEPENDENCY
    )
    assert_equal "merge", dependency.metadata["generated_by"]
    assert_equal source_subgraph.id, dependency.metadata["source_subgraph_id"]

    source_subgraph.reload
    assert source_subgraph.archived_at.blank?
    assert_nil source_subgraph.merged_into_subgraph_id

    followup =
      graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, subgraph_id: source_subgraph.id, metadata: {})
    assert_equal source_subgraph.id, followup.subgraph_id
  end

  test "main subgraph cannot be merged into another subgraph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_subgraph = graph.main_subgraph

    main_head = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_equal main_subgraph.id, main_head.subgraph_id

    branch_subgraph = graph.subgraphs.create!(role: DAG::Subgraph::BRANCH, parent_subgraph_id: main_subgraph.id, metadata: {})
    branch_head = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      subgraph_id: branch_subgraph.id,
      metadata: {}
    )

    assert_raises(ArgumentError) do
      graph.mutate! do |m|
        m.merge_subgraphs!(
          target_subgraph: branch_subgraph,
          target_from_node: branch_head,
          source_subgraphs_and_nodes: [{ subgraph: main_subgraph, from_node: main_head }],
          node_type: Messages::AgentMessage.node_type_key,
          metadata: {}
        )
      end
    end
  end
end
