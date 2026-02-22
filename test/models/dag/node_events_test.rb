require "test_helper"

class DAG::NodeEventsTest < ActiveSupport::TestCase
  test "node_event_page_for returns a bounded, keyset-pageable stream" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, body_output: { "content" => "ok" }, metadata: {})

    first =
      DAG::NodeEvent.create!(
        graph_id: graph.id,
        node_id: node.id,
        kind: DAG::NodeEvent::OUTPUT_DELTA,
        text: "a",
        payload: {}
      )
    second =
      DAG::NodeEvent.create!(
        graph_id: graph.id,
        node_id: node.id,
        kind: DAG::NodeEvent::PROGRESS,
        payload: { "phase" => "llm", "message" => "streaming" }
      )

    page = graph.node_event_page_for(node.id)
    assert_equal [first.id, second.id], page.map { |event| event.fetch("event_id") }

    after_first = graph.node_event_page_for(node.id, after_event_id: first.id)
    assert_equal [second.id], after_first.map { |event| event.fetch("event_id") }

    deltas = graph.node_event_page_for(node.id, kinds: [DAG::NodeEvent::OUTPUT_DELTA])
    assert_equal [first.id], deltas.map { |event| event.fetch("event_id") }
  end

  test "node_event_page_for rejects non-positive limits and node_event_scope_for is a relation" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, body_output: { "content" => "ok" }, metadata: {})

    assert_raises(DAG::PaginationError) { graph.node_event_page_for(node.id, limit: 0) }

    scope = graph.node_event_scope_for(node.id)
    assert scope.is_a?(ActiveRecord::Relation)
  end
end
