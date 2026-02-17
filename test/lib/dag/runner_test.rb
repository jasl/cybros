require "test_helper"

class DAG::RunnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SkipExecutor
    def execute(node:, context:)
      _ = node
      _ = context
      DAG::ExecutionResult.skipped(reason: "not needed")
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "runner treats skipped execution results as errors for running nodes" do
    conversation = Conversation.create!
    node = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(DAG::Node::TASK, SkipExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    DAG::Runner.run_node!(node.id)

    assert_equal DAG::Node::ERRORED, node.reload.state
    assert_includes node.metadata.fetch("error"), "skipped_for_running_node"
    assert_enqueued_with(job: DAG::TickConversationJob, args: [conversation.id])
  ensure
    DAG.executor_registry = original_registry
  end
end

