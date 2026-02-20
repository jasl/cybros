require "test_helper"

class DAG::GraphSemanticsTest < ActiveSupport::TestCase
  test "validate_leaf_invariant! repairs leaves for attachable graphs" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    leaf = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    created = graph.with_graph_lock! { graph.validate_leaf_invariant! }
    assert created

    repaired = graph.nodes.find_by!(metadata: { "generated_by" => "leaf_invariant" })
    assert_equal Messages::AgentMessage.node_type_key, repaired.node_type
    assert_equal DAG::Node::PENDING, repaired.state
    assert_equal leaf.lane_id, repaired.lane_id

    assert graph.edges.exists?(
      from_node_id: leaf.id,
      to_node_id: repaired.id,
      edge_type: DAG::Edge::SEQUENCE,
      metadata: { "generated_by" => "leaf_invariant" }
    )
  end

  test "transcript_for delegates inclusion decisions to NodeBody class hooks" do
    Messages.const_set(
      :CustomTranscriptMessage,
      Class.new(::DAG::NodeBody) do
        class << self
          def transcript_include?(_context_node_hash)
            true
          end
        end
      end
    )

    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    custom = graph.nodes.create!(
      node_type: "custom_transcript_message",
      state: DAG::Node::FINISHED,
      body_output: { "content" => "visible" },
      metadata: {}
    )
    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )

    graph.edges.create!(from_node_id: user.id, to_node_id: custom.id, edge_type: DAG::Edge::SEQUENCE, metadata: {})
    graph.edges.create!(from_node_id: custom.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE, metadata: {})

    transcript = graph.transcript_for(agent.id)
    assert_equal [Messages::UserMessage.node_type_key, "custom_transcript_message", Messages::AgentMessage.node_type_key],
                 transcript.map { |node| node["node_type"] }
  ensure
    Messages.send(:remove_const, :CustomTranscriptMessage) if Messages.const_defined?(:CustomTranscriptMessage, false)
  end

  test "scheduler uses graph claim_lease_seconds_for" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    child = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    graph.define_singleton_method(:claim_lease_seconds_for) { |_node| 5.seconds }

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [child.id], claimed.map(&:id)

    child.reload
    assert_equal 5, (child.lease_expires_at - child.claimed_at).to_i
  ensure
    graph.singleton_class.send(:remove_method, :claim_lease_seconds_for)
  end
end
