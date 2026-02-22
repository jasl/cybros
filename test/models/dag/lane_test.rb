require "test_helper"

class DAG::LaneTest < ActiveSupport::TestCase
  test "graph automatically has a unique main lane" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    assert_equal 1, graph.lanes.where(role: DAG::Lane::MAIN).count
    assert_equal graph.lanes.find_by!(role: DAG::Lane::MAIN), graph.main_lane

    assert_raises(ActiveRecord::RecordNotUnique) do
      graph.lanes.create!(role: DAG::Lane::MAIN, metadata: {})
    end
  end

  test "lane relationship pointers must not cross graphs" do
    conversation_a = Conversation.create!
    graph_a = conversation_a.dag_graph
    lane_a = graph_a.main_lane

    conversation_b = Conversation.create!
    graph_b = conversation_b.dag_graph

    assert_raises(ActiveRecord::RecordInvalid) do
      graph_b.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: lane_a.id, metadata: {})
    end
  end

  test "root_node_id must belong to the lane" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    lane_a = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})
    lane_b = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})

    node_in_a =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane_a.id,
        metadata: {}
      )

    assert_raises(ActiveRecord::RecordInvalid) do
      lane_b.update!(root_node_id: node_in_a.id)
    end
  end

  test "nodes default to graph.main_lane for both direct creates and mutation creates" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    direct = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    assert_equal main_lane.id, direct.lane_id

    via_mutation = nil
    graph.mutate! do |m|
      via_mutation = m.create_node(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    end
    assert_equal main_lane.id, via_mutation.lane_id
  end

  test "lane-scoped context_for rejects target nodes that belong to a different lane" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    branch_lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})

    main = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, lane_id: main_lane.id, metadata: {})
    branch = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, lane_id: branch_lane.id, metadata: {})

    error = assert_raises(DAG::ValidationError) { main_lane.context_for(branch.id) }
    assert_match(/must belong to this lane/, error.message)

    error = assert_raises(DAG::ValidationError) { branch_lane.context_for(main.id) }
    assert_match(/must belong to this lane/, error.message)
  end

  test "create_node inherits lane_id from existing nodes in the same turn" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})
    turn_id = "0194f3c0-0000-7000-8000-00000000d001"

    anchor = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      lane_id: lane.id,
      turn_id: turn_id,
      metadata: {}
    )

    created = nil
    graph.mutate!(turn_id: turn_id) do |m|
      created = m.create_node(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    end

    assert_equal anchor.lane_id, created.lane_id
  end

  test "fork creates a new branch lane and leaf repair stays within that lane" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    from = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )
    assert_equal main_lane.id, from.lane_id

    forked_user =
      from.fork!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        body_input: { "content" => "branch" },
        metadata: {}
      )

    lane = forked_user.lane
    assert_equal DAG::Lane::BRANCH, lane.role
    assert_equal main_lane.id, lane.parent_lane_id
    assert_equal from.id, lane.forked_from_node_id
    assert_equal forked_user.id, lane.root_node_id

    repaired = graph.nodes.active.find_by!(
      lane_id: lane.id,
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      metadata: { "generated_by" => "leaf_invariant" }
    )
    assert_equal forked_user.turn_id, repaired.turn_id
  end

  test "archived lanes block new turns but allow existing turns" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})
    turn_id = "0194f3c0-0000-7000-8000-00000000d002"

    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_id,
      metadata: {}
    )

    lane.update!(archived_at: Time.current)

    continued =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        metadata: {}
      )
    assert_equal lane.id, continued.lane_id
    assert_equal turn_id, continued.turn_id

    error =
      assert_raises(ActiveRecord::RecordInvalid) do
        graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, lane_id: lane.id, metadata: {})
      end
    assert_match(/Lane is archived/, error.message)
  end

  test "archive_lane! mode cancel stops running and pending without creating new pending work" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})

    running = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, lane_id: lane.id, metadata: {})
    pending = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, lane_id: lane.id, metadata: {})

    graph.mutate! do |m|
      m.archive_lane!(lane: lane, mode: :cancel, at: Time.current, reason: "stopped_by_user")
    end

    state_events =
      conversation.events
        .where(event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED)
        .pluck(:subject_id, :particulars)
        .to_h
    assert_equal({ "from" => "running", "to" => "stopped" }, state_events.fetch(running.id))
    assert_equal({ "from" => "pending", "to" => "stopped" }, state_events.fetch(pending.id))

    lane.reload
    assert lane.archived_at.present?

    assert_equal DAG::Node::STOPPED, running.reload.state
    assert_equal "stopped_by_user", running.metadata["reason"]
    assert running.finished_at.present?

    assert_equal DAG::Node::STOPPED, pending.reload.state
    assert_equal "stopped_by_user", pending.metadata["reason"]
    assert pending.finished_at.present?

    assert graph.nodes.active.where(lane_id: lane.id, state: DAG::Node::PENDING).none?
    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end

  test "merge creates a pending join node in the target lane without archiving the source lanes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    main_head = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_equal main_lane.id, main_head.lane_id

    source_lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})
    source_head = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: source_lane.id,
      metadata: {}
    )

    merge_node = nil
    graph.mutate! do |m|
      merge_node =
        m.merge_lanes!(
          target_lane: main_lane,
          target_from_node: main_head,
          source_lanes_and_nodes: [{ lane: source_lane, from_node: source_head }],
          node_type: Messages::AgentMessage.node_type_key,
          metadata: { "kind" => "test" }
        )
    end

    assert_equal main_lane.id, merge_node.lane_id
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
    assert_equal source_lane.id, dependency.metadata["source_lane_id"]

    source_lane.reload
    assert source_lane.archived_at.blank?
    assert_nil source_lane.merged_into_lane_id

    followup =
      graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, lane_id: source_lane.id, metadata: {})
    assert_equal source_lane.id, followup.lane_id
  end

  test "main lane cannot be merged into another lane" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    main_head = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_equal main_lane.id, main_head.lane_id

    branch_lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})
    branch_head = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: branch_lane.id,
      metadata: {}
    )

    assert_raises(DAG::ValidationError) do
      graph.mutate! do |m|
        m.merge_lanes!(
          target_lane: branch_lane,
          target_from_node: branch_head,
          source_lanes_and_nodes: [{ lane: main_lane, from_node: main_head }],
          node_type: Messages::AgentMessage.node_type_key,
          metadata: {}
        )
      end
    end
  end
end
