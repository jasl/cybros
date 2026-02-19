require "test_helper"

class DAG::AdoptVersionTest < ActiveSupport::TestCase
  test "adopt_version! switches the active version within a version_set_id" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        body_input: { "content" => "hi" },
        metadata: {}
      )

    v1 =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        body_output: { "content" => "v1" },
        metadata: {},
      )

    graph.edges.create!(from_node_id: user.id, to_node_id: v1.id, edge_type: DAG::Edge::SEQUENCE)

    v2 = v1.rerun!
    v2.mark_running!
    v2.mark_finished!(content: "v2")

    v3 = v2.rerun!
    v3.mark_running!
    v3.mark_finished!(content: "v3")

    assert_equal v1.version_set_id, v2.version_set_id
    assert_equal v2.version_set_id, v3.version_set_id

    assert_equal [v1.id, v2.id, v3.id], v1.versions.pluck(:id)
    assert_equal 3, v1.version_count
    assert_equal 1, v1.version_number
    assert_equal 2, v2.version_number
    assert_equal 3, v3.version_number

    assert_equal [v3.id], v3.versions(include_inactive: false).pluck(:id)

    adopted = v1.adopt_version!

    assert_equal v1.id, adopted.id
    assert_equal [v1.id], graph.nodes.active.where(version_set_id: v1.version_set_id).pluck(:id)

    context_ids = graph.context_for(adopted.id).map { |node| node.fetch("node_id") }
    assert_equal [user.id, v1.id], context_ids

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end
end
