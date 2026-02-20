require "test_helper"

class DAG::SubagentChildConversationFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SpawnChildConversationExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream

      child = Conversation.create!
      child_graph = child.dag_graph
      child_turn_id = "0194f3c0-0000-7000-8000-00000000c100"

      child_graph.mutate!(turn_id: child_turn_id) do |m|
        user =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "child: hello",
            metadata: {}
          )
        agent =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "child: world",
            metadata: {}
          )

        m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
      end

      child_ids = {
        "child_conversation_id" => child.id,
        "child_graph_id" => child_graph.id,
      }

      DAG::ExecutionResult.finished(
        payload: { "result" => child_ids },
        metadata: { "subagent" => child_ids },
        usage: { "total_tokens" => 1 }
      )
    end
  end

  class SummarizeChildConversationExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = stream

      task = context.find { |context_node| context_node.fetch("node_type") == Messages::Task.node_type_key }
      raise "expected task in context" if task.nil?

      subagent = task.fetch("metadata").fetch("subagent")
      child_conversation_id = subagent.fetch("child_conversation_id")

      child = Conversation.find(child_conversation_id)
      child_transcript = child.transcript_recent_turns(limit_turns: 10)

      rendered =
        child_transcript.map do |context_node|
          case context_node.fetch("node_type")
          when Messages::UserMessage.node_type_key
            "U:#{context_node.dig("payload", "input", "content")}"
          when Messages::AgentMessage.node_type_key
            "A:#{context_node.dig("payload", "output_preview", "content")}"
          else
            nil
          end
        end.compact.join(" | ")

      DAG::ExecutionResult.finished(
        payload: { "content" => "Subagent transcript: #{rendered}" },
        usage: { "total_tokens" => 1 }
      )
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "subagent pattern: parent task creates child conversation, parent agent reads bounded child transcript" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c020"

    user = nil
    task = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "hi", metadata: {})
      task = m.create_node(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

      m.create_edge(from_node: user, to_node: task, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task, to_node: agent, edge_type: DAG::Edge::DEPENDENCY)
    end

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, SpawnChildConversationExecutor.new)
    registry.register(Messages::AgentMessage.node_type_key, SummarizeChildConversationExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)
      DAG::Runner.run_node!(task.id)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_includes agent.body_output.fetch("content"), "Subagent transcript:"
      assert_includes agent.body_output.fetch("content"), "child: hello"
      assert_includes agent.body_output.fetch("content"), "child: world"

      transcript = conversation.transcript_for(agent.id)
      assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key], transcript.map { |node| node.fetch("node_type") }

      child_ids = task.reload.metadata.fetch("subagent")
      child_graph_id = child_ids.fetch("child_graph_id")

      child_conversation = Conversation.find(child_ids.fetch("child_conversation_id"))
      assert_equal child_graph_id, child_conversation.dag_graph.id

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
      assert_equal [], DAG::GraphAudit.scan(graph: child_conversation.dag_graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
