require "test_helper"

class DAG::ExecuteNodeJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  class FakeTaskExecutor
    def execute(node:, context:)
      _ = node
      _ = context
      DAG::ExecutionResult.finished(metadata: { "ok" => true })
    end
  end

  class FakeAgentMessageExecutor
    def execute(node:, context:)
      _ = node
      _ = context
      DAG::ExecutionResult.finished(content: "done")
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "execute job runs the node and advances until the leaf is an agent_message" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: { "name" => "t" })

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, FakeTaskExecutor.new)
    registry.register(Messages::AgentMessage.node_type_key, FakeAgentMessageExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    perform_enqueued_jobs do
      conversation.kick!
    end

    leaf = graph.leaf_nodes.first
    assert_equal Messages::AgentMessage.node_type_key, leaf.node_type
    assert_equal DAG::Node::FINISHED, leaf.state
    assert_equal "done", leaf.body_output["content"]
  ensure
    DAG.executor_registry = original_registry
  end
end
