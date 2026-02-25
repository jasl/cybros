require "test_helper"

class DAG::StopGenerationStreamingFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "stop generation while streaming: output deltas are compacted and partial output stays readable via transcript pagination" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane
    turn_id = "0194f3c0-0000-7000-8000-00000000e401"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f401",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {}
        )
      agent =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f402",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {}
        )
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, agent.reload.state

    stream = DAG::NodeEventStream.new(node: agent)
    stream.output_delta!("Hel")
    stream.output_delta!("lo")
    stream.flush!

    output_deltas = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_DELTA])
    assert_equal 2, output_deltas.length
    assert_equal %w[Hel lo], output_deltas.map { |event| event.fetch("text") }

    assert agent.stop!(reason: "user_cancelled")
    agent.reload
    assert_equal DAG::Node::STOPPED, agent.state
    assert_equal "Hello", agent.body_output["content"]

    output_deltas = lane.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_DELTA])
    assert_equal [], output_deltas

    compacted = lane.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_COMPACTED])
    assert_equal 1, compacted.length
    assert_equal 2, compacted.first.dig("payload", "chunks")
    assert_equal "Hello".bytesize, compacted.first.dig("payload", "bytes")
    assert_equal Digest::SHA256.hexdigest("Hello"), compacted.first.dig("payload", "sha256")

    transcript_page = lane.transcript_page(limit_turns: 10)
    contents =
      transcript_page.fetch("transcript").map do |node|
        node.dig("payload", "input", "content").to_s.presence ||
          node.dig("payload", "output_preview", "content").to_s
      end
    assert_equal ["Hi", "Hello"], contents

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end
end
