require "test_helper"

class DAG::ChatbotStreamingFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class StreamingExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = context

      stream.output_delta!("你")
      stream.output_delta!("好")
      stream.progress(phase: "llm", message: "streaming")

      DAG::ExecutionResult.finished_streamed(
        usage: { "total_tokens" => 1 }
      )
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "chatbot streaming flow: executor streams output deltas, final output is materialized, and node events are queryable" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c012"

    system = nil
    developer = nil
    user = nil

    graph.mutate!(turn_id: turn_id) do |m|
      system = m.create_node(node_type: Messages::SystemMessage.node_type_key, state: DAG::Node::FINISHED, content: "You are helpful", metadata: {})
      developer = m.create_node(node_type: Messages::DeveloperMessage.node_type_key, state: DAG::Node::FINISHED, content: "Answer in Chinese", metadata: {})
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})

      m.create_edge(from_node: system, to_node: developer, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: developer, to_node: user, edge_type: DAG::Edge::SEQUENCE)
    end

    agent = graph.nodes.active.find_by!(turn_id: turn_id, node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, StreamingExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "你好", agent.body_output["content"]

      output_deltas = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_DELTA])
      assert_equal [], output_deltas

      compacted = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_COMPACTED])
      assert_equal 1, compacted.length
      assert_equal 2, compacted.first.dig("payload", "chunks")
      assert_equal "你好".bytesize, compacted.first.dig("payload", "bytes")
      assert_equal Digest::SHA256.hexdigest("你好"), compacted.first.dig("payload", "sha256")

      progress = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::PROGRESS])
      assert progress.any?

      context = agent.lane.context_for(agent.id)
      context_ids = context.map { |node| node.fetch("node_id") }
      assert_equal [system.id, developer.id, user.id, agent.id], context_ids

      full = agent.lane.context_for_full(agent.id)
      agent_full = full.find { |node| node.fetch("node_id") == agent.id }
      assert_equal "你好", agent_full.dig("payload", "output", "content")

      transcript = graph.transcript_for(agent.id)
      assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key], transcript.map { |node| node.fetch("node_type") }
      assert_equal "你好", transcript.last.dig("payload", "output_preview", "content")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
