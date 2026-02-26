require "test_helper"

class DAG::NodeEventStreamTest < ActiveSupport::TestCase
  test "output_delta! creates an event and patches output_preview" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    node =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::RUNNING,
        metadata: {}
      )

    stream = DAG::NodeEventStream.new(node: node)
    stream.output_delta!("hello")

    deltas =
      DAG::NodeEvent
        .where(graph_id: graph.id, node_id: node.id, kind: DAG::NodeEvent::OUTPUT_DELTA)
        .order(:id)
        .pluck(:text)
    assert_equal ["hello"], deltas

    assert_equal "hello", node.body.reload.output_preview["content"]
  end
end
