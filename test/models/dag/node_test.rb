require "test_helper"

class DAG::NodeTest < ActiveSupport::TestCase
  test "creates the correct body STI class for each node_type by default" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    system = graph.nodes.create!(node_type: Messages::SystemMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_instance_of Messages::SystemMessage, system.body

    developer = graph.nodes.create!(node_type: Messages::DeveloperMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_instance_of Messages::DeveloperMessage, developer.body

    user = graph.nodes.create!(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_instance_of Messages::UserMessage, user.body

    agent = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    assert_instance_of Messages::AgentMessage, agent.body

    character = graph.nodes.create!(node_type: Messages::CharacterMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    assert_instance_of Messages::CharacterMessage, character.body

    task = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    assert_instance_of Messages::Task, task.body

    summary = graph.nodes.create!(node_type: Messages::Summary.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    assert_instance_of Messages::Summary, summary.body
  end

  test "is invalid when body STI does not match node_type" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.new(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    node.body = Messages::AgentMessage.new

    assert_not node.valid?
    assert_match(/Messages::Task/, node.errors[:body].join)
  end

  test "is invalid when node_type is unknown for the graph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.new(node_type: "bogus", state: DAG::Node::PENDING, metadata: {})
    assert_not node.valid?
    assert_includes node.errors[:node_type], "is unknown"

    error = assert_raises(ActiveRecord::RecordInvalid) do
      node.save!
    end
    assert_match(/Node type is unknown/, error.message)
  end

  test "is invalid when a non-executable node is pending" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.new(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

    assert_not node.valid?
    assert_includes node.errors[:state], "can only be pending/awaiting_approval/running for executable nodes"
  end

  test "exclude_from_context! and soft_delete! reject non-terminal nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    error = assert_raises(ArgumentError) { node.exclude_from_context! }
    assert_match(/terminal/, error.message)

    error = assert_raises(ArgumentError) { node.soft_delete! }
    assert_match(/terminal/, error.message)
  end

  test "exclude_from_context! and soft_delete! reject mutations while graph has running nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    _running = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    terminal = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    error = assert_raises(ArgumentError) { terminal.exclude_from_context! }
    assert_match(/running nodes/, error.message)

    error = assert_raises(ArgumentError) { terminal.soft_delete! }
    assert_match(/running nodes/, error.message)
  end

  test "can_* visibility helpers reflect strict gating and current flags" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert node.can_exclude_from_context?
    assert_not node.can_include_in_context?
    assert node.can_soft_delete?
    assert_not node.can_restore?

    node.exclude_from_context!
    assert_not node.can_exclude_from_context?
    assert node.can_include_in_context?

    node.soft_delete!
    assert_not node.can_soft_delete?
    assert node.can_restore?

    graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    assert_not node.can_include_in_context?
    assert_not node.can_restore?
  end

  test "can_* mutation helpers match retry/edit/rerun/fork preconditions" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    task = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, metadata: {})
    downstream = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: task.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)
    assert task.can_retry?

    downstream.update!(state: DAG::Node::FINISHED)
    assert_not task.can_retry?

    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )
    assert agent.can_rerun?

    child = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: agent.id, to_node_id: child.id, edge_type: DAG::Edge::SEQUENCE)
    assert_not agent.can_rerun?

    user = graph.nodes.create!(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, body_input: { "content" => "hi" }, metadata: {})
    assert user.can_edit?

    running = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    graph.edges.create!(from_node_id: user.id, to_node_id: running.id, edge_type: DAG::Edge::SEQUENCE)
    assert_not user.can_edit?

    assert user.can_fork?
    pending = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    assert_not pending.can_fork?
  end

  test "retry! rejects attempts when downstream nodes are not pending" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, metadata: {})
    downstream = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    error = assert_raises(ArgumentError) { original.retry! }
    assert_match(/downstream nodes are not pending/, error.message)
  end

  test "retry! rejects non-retriable node types" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::ERRORED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    error = assert_raises(ArgumentError) { original.retry! }
    assert_match(/retriable/, error.message)
  end

  test "edit! rejects attempts when downstream nodes are pending or running" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, body_input: { "content" => "hi" }, metadata: {})
    downstream = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    error = assert_raises(ArgumentError) { original.edit!(new_input: { "content" => "hi2" }) }
    assert_match(/downstream nodes are pending or running/, error.message)
  end

  test "rerun! rejects attempts when agent_message is not a leaf" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )
    downstream = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    error = assert_raises(ArgumentError) { original.rerun! }
    assert_match(/leaf/, error.message)
  end

  test "retry! creates a replacement attempt, rewires outgoing blocking edges, and archives the old node" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    original = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, metadata: {})
    downstream = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: original.id, edge_type: DAG::Edge::DEPENDENCY)
    original_to_downstream = graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    retried = original.retry!

    assert_equal DAG::Node::PENDING, retried.state
    assert_equal original.lane_id, retried.lane_id
    assert_equal original.id, retried.retry_of_id
    assert_equal original.turn_id, retried.turn_id
    assert_equal original.version_set_id, retried.version_set_id
    assert_equal 2, retried.metadata["attempt"]
    assert original.reload.compressed_at.present?
    assert_equal retried.id, original.compressed_by_id

    assert graph.edges.active.exists?(
      from_node_id: parent.id,
      to_node_id: retried.id,
      edge_type: DAG::Edge::DEPENDENCY
    )

    assert graph.edges.active.exists?(
      from_node_id: retried.id,
      to_node_id: downstream.id,
      edge_type: DAG::Edge::SEQUENCE
    )

    assert original_to_downstream.reload.compressed_at.present?

    branch_edge = graph.edges.find_by!(
      from_node_id: original.id,
      to_node_id: retried.id,
      edge_type: DAG::Edge::BRANCH
    )
    assert_equal ["retry"], branch_edge.metadata["branch_kinds"]
    assert branch_edge.compressed_at.present?
  end

  test "retry! copies body_input and clears output" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::ERRORED,
      body_input: { "name" => "t", "arguments" => { "a" => 1 } },
      body_output: { "result" => "old" },
      metadata: {}
    )

    retried = original.retry!

    assert_equal DAG::Node::PENDING, retried.state
    assert_equal original.lane_id, retried.lane_id
    assert_equal "t", retried.body_input["name"]
    assert_equal({ "a" => 1 }, retried.body_input["arguments"])
    assert_equal({}, retried.body_output)
  end

  test "retry! clears state-specific metadata fields (error/reason) but preserves custom metadata" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::ERRORED,
      body_input: { "name" => "t" },
      metadata: {
        "error" => "boom",
        "reason" => "nope",
        "attempt" => 3,
        "custom" => "x",
        "usage" => { "total_tokens" => 123 },
        "output_stats" => { "body_output_bytes" => 99 },
        "timing" => { "run_duration_ms" => 1 },
        "worker" => { "execute_job_id" => "j1" },
      }
    )

    retried = original.retry!

    assert_equal original.lane_id, retried.lane_id
    assert_nil retried.metadata["error"]
    assert_nil retried.metadata["reason"]
    assert_nil retried.metadata["usage"]
    assert_nil retried.metadata["output_stats"]
    assert_nil retried.metadata["timing"]
    assert_nil retried.metadata["worker"]
    assert_equal "x", retried.metadata["custom"]
    assert_equal 4, retried.metadata["attempt"]
  end

  test "rerun! replaces a finished agent_message leaf" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    original = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {
        "usage" => { "total_tokens" => 10 },
        "output_stats" => { "body_output_bytes" => 1 },
        "timing" => { "run_duration_ms" => 1 },
        "worker" => { "execute_job_id" => "j1" },
      }
    )
    edge = graph.edges.create!(
      from_node_id: user.id,
      to_node_id: original.id,
      edge_type: DAG::Edge::SEQUENCE
    )

    rerun_node = original.rerun!

    assert_equal DAG::Node::PENDING, rerun_node.state
    assert_equal Messages::AgentMessage.node_type_key, rerun_node.node_type
    assert_equal original.lane_id, rerun_node.lane_id
    assert_equal original.turn_id, rerun_node.turn_id
    assert_equal original.version_set_id, rerun_node.version_set_id
    assert_nil rerun_node.metadata["usage"]
    assert_nil rerun_node.metadata["output_stats"]
    assert_nil rerun_node.metadata["timing"]
    assert_nil rerun_node.metadata["worker"]

    assert original.reload.compressed_at.present?
    assert_equal rerun_node.id, original.compressed_by_id

    assert graph.edges.active.exists?(
      from_node_id: user.id,
      to_node_id: rerun_node.id,
      edge_type: DAG::Edge::SEQUENCE
    )
    assert edge.reload.compressed_at.present?
  end

  test "edit! archives downstream causal subgraph and creates a new mainline user_message" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {
        "usage" => { "total_tokens" => 1 },
        "output_stats" => { "body_output_bytes" => 2 },
        "timing" => { "run_duration_ms" => 1 },
        "worker" => { "execute_job_id" => "j1" },
      }
    )
    b = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )
    c = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    d = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "bye" },
      metadata: {}
    )

    graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: c.id, to_node_id: d.id, edge_type: DAG::Edge::SEQUENCE)

    edited = a.edit!(new_input: { "content" => "hi2" })

    assert_equal DAG::Node::FINISHED, edited.state
    assert_equal a.lane_id, edited.lane_id
    assert_equal a.turn_id, edited.turn_id
    assert_equal a.version_set_id, edited.version_set_id
    assert_equal "hi2", edited.body_input["content"]
    assert_nil edited.metadata["usage"]
    assert_nil edited.metadata["output_stats"]
    assert_nil edited.metadata["timing"]
    assert_nil edited.metadata["worker"]

    [a, b, c, d].each do |node|
      assert node.reload.compressed_at.present?
      assert_equal edited.id, node.compressed_by_id
    end

    leaves = graph.leaf_nodes.to_a
    assert_equal 1, leaves.length

    leaf = leaves.first
    assert_equal Messages::AgentMessage.node_type_key, leaf.node_type
    assert_equal DAG::Node::PENDING, leaf.state

    assert graph.edges.active.exists?(
      from_node_id: edited.id,
      to_node_id: leaf.id,
      edge_type: DAG::Edge::SEQUENCE
    )
  end

  test "mark_stopped! works from running" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    assert node.mark_stopped!(reason: "stopped by user")
    assert_equal DAG::Node::STOPPED, node.state
    assert_equal "stopped by user", node.metadata["reason"]
  end

  test "mark_stopped! does not transition from pending" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    assert_not node.mark_stopped!(reason: "cannot stop before running")
    assert_equal DAG::Node::PENDING, node.reload.state
  end

  test "mark_skipped! works from pending" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    assert node.mark_skipped!(reason: "no longer needed")
    assert_equal DAG::Node::SKIPPED, node.state
    assert_equal "no longer needed", node.metadata["reason"]
  end

  test "mark_skipped! does not transition from running" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})

    assert_not node.mark_skipped!(reason: "cannot skip after running")
    assert_equal DAG::Node::RUNNING, node.reload.state
  end

  test "turn_id cannot span multiple lanes within a graph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    branch_lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})
    turn_id = "0194f3c0-0000-7000-8000-00000000f001"

    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: branch_lane.id,
      turn_id: turn_id,
      metadata: {}
    )

    error =
      assert_raises(ActiveRecord::RecordInvalid) do
        graph.nodes.create!(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: main_lane.id,
          turn_id: turn_id,
          metadata: {}
        )
      end
    assert_match(/must match existing nodes for this turn/, error.message)
  end
end
