require "test_helper"

class DAG::NodeTest < ActiveSupport::TestCase
  test "creates the correct payload STI class for each node_type by default" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(node_type: DAG::Node::USER_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    assert_instance_of Messages::UserMessage, user.payload

    agent = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    assert_instance_of Messages::AgentMessage, agent.payload

    task = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    assert_instance_of Messages::ToolCall, task.payload

    summary = graph.nodes.create!(node_type: DAG::Node::SUMMARY, state: DAG::Node::FINISHED, metadata: {})
    assert_instance_of Messages::Summary, summary.payload
  end

  test "is invalid when payload STI does not match node_type" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.new(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    node.payload = Messages::AgentMessage.new

    assert_not node.valid?
    assert_match(/Messages::ToolCall/, node.errors[:payload].join)
  end

  test "retry! rejects attempts when downstream nodes are not pending" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    downstream = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    error = assert_raises(ArgumentError) { original.retry! }
    assert_match(/downstream nodes are not pending/, error.message)
  end

  test "edit! rejects attempts when downstream nodes are pending or running" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(node_type: DAG::Node::USER_MESSAGE, state: DAG::Node::FINISHED, payload_input: { "content" => "hi" }, metadata: {})
    downstream = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})
    graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    error = assert_raises(ArgumentError) { original.edit!(new_input: { "content" => "hi2" }) }
    assert_match(/downstream nodes are pending or running/, error.message)
  end

  test "regenerate! rejects attempts when agent_message is not a leaf" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_output: { "content" => "hello" },
      metadata: {}
    )
    downstream = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    error = assert_raises(ArgumentError) { original.regenerate! }
    assert_match(/leaf agent_message/, error.message)
  end

  test "retry! creates a replacement attempt, rewires outgoing blocking edges, and archives the old node" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    original = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
    downstream = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: original.id, edge_type: DAG::Edge::DEPENDENCY)
    original_to_downstream = graph.edges.create!(from_node_id: original.id, to_node_id: downstream.id, edge_type: DAG::Edge::SEQUENCE)

    retried = original.retry!

    assert_equal DAG::Node::PENDING, retried.state
    assert_equal original.id, retried.retry_of_id
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

  test "retry! copies payload_input and clears output" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::ERRORED,
      payload_input: { "name" => "t", "arguments" => { "a" => 1 } },
      payload_output: { "result" => "old" },
      metadata: {}
    )

    retried = original.retry!

    assert_equal DAG::Node::PENDING, retried.state
    assert_equal "t", retried.payload_input["name"]
    assert_equal({ "a" => 1 }, retried.payload_input["arguments"])
    assert_equal({}, retried.payload_output)
  end

  test "retry! clears state-specific metadata fields (error/reason) but preserves custom metadata" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    original = graph.nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::ERRORED,
      payload_input: { "name" => "t" },
      metadata: { "error" => "boom", "reason" => "nope", "attempt" => 3, "custom" => "x" }
    )

    retried = original.retry!

    assert_nil retried.metadata["error"]
    assert_nil retried.metadata["reason"]
    assert_equal "x", retried.metadata["custom"]
    assert_equal 4, retried.metadata["attempt"]
  end

  test "regenerate! replaces a finished agent_message leaf" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_input: { "content" => "hi" },
      metadata: {}
    )
    original = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_output: { "content" => "hello" },
      metadata: {}
    )
    edge = graph.edges.create!(
      from_node_id: user.id,
      to_node_id: original.id,
      edge_type: DAG::Edge::SEQUENCE
    )

    regenerated = original.regenerate!

    assert_equal DAG::Node::PENDING, regenerated.state
    assert_equal DAG::Node::AGENT_MESSAGE, regenerated.node_type

    assert original.reload.compressed_at.present?
    assert_equal regenerated.id, original.compressed_by_id

    assert graph.edges.active.exists?(
      from_node_id: user.id,
      to_node_id: regenerated.id,
      edge_type: DAG::Edge::SEQUENCE
    )
    assert edge.reload.compressed_at.present?
  end

  test "edit! archives downstream causal subgraph and creates a new mainline user_message" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_input: { "content" => "hi" },
      metadata: {}
    )
    b = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_output: { "content" => "hello" },
      metadata: {}
    )
    c = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    d = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      payload_output: { "content" => "bye" },
      metadata: {}
    )

    graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: b.id, to_node_id: c.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: c.id, to_node_id: d.id, edge_type: DAG::Edge::SEQUENCE)

    edited = a.edit!(new_input: { "content" => "hi2" })

    assert_equal DAG::Node::FINISHED, edited.state
    assert_equal "hi2", edited.payload_input["content"]

    [a, b, c, d].each do |node|
      assert node.reload.compressed_at.present?
      assert_equal edited.id, node.compressed_by_id
    end

    leaves = graph.leaf_nodes.to_a
    assert_equal 1, leaves.length

    leaf = leaves.first
    assert_equal DAG::Node::AGENT_MESSAGE, leaf.node_type
    assert_equal DAG::Node::PENDING, leaf.state

    assert graph.edges.active.exists?(
      from_node_id: edited.id,
      to_node_id: leaf.id,
      edge_type: DAG::Edge::SEQUENCE
    )
  end

  test "mark_cancelled! works from running" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})

    assert node.mark_cancelled!(reason: "cancelled by user")
    assert_equal DAG::Node::CANCELLED, node.state
    assert_equal "cancelled by user", node.metadata["reason"]
  end

  test "mark_cancelled! does not transition from pending" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    assert_not node.mark_cancelled!(reason: "cannot cancel before running")
    assert_equal DAG::Node::PENDING, node.reload.state
  end

  test "mark_skipped! works from pending" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    assert node.mark_skipped!(reason: "no longer needed")
    assert_equal DAG::Node::SKIPPED, node.state
    assert_equal "no longer needed", node.metadata["reason"]
  end

  test "mark_skipped! does not transition from running" do
    conversation = Conversation.create!
    node = conversation.dag_graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})

    assert_not node.mark_skipped!(reason: "cannot skip after running")
    assert_equal DAG::Node::RUNNING, node.reload.state
  end
end
