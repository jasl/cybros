require "test_helper"

class DAG::ChatbotFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FixedContentExecutor
    def initialize(content)
      @content = content
    end

    def execute(node:, context:)
      _ = node
      _ = context

      DAG::ExecutionResult.finished(payload: { "content" => @content }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "chatbot flow: system+developer+user context, leaf repair, and transcript excludes system/developer" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c001"

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

    repaired = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).to_a
    assert_equal 1, repaired.length
    agent = repaired.first

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, FixedContentExecutor.new("你好"))

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent.id)

      context = conversation.context_for(agent.id)
      context_ids = context.map { |node| node.fetch("node_id") }
      assert_equal [system.id, developer.id, user.id, agent.id], context_ids

      transcript = conversation.transcript_for(agent.id)
      assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key], transcript.map { |node| node.fetch("node_type") }
      assert_equal "你好", transcript.last.dig("payload", "output_preview", "content")

      assert conversation.events.exists?(event_type: DAG::GraphHooks::EventTypes::LEAF_INVARIANT_REPAIRED, subject: agent)
      assert conversation.events.exists?(event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED, subject: agent)

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
