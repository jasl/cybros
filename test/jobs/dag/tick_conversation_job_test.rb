require "test_helper"

class DAG::TickConversationJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "tick claims runnable nodes and enqueues execute jobs" do
    conversation = Conversation.create!
    node = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    DAG::TickConversationJob.perform_now(conversation.id, limit: 10)

    assert_enqueued_with(job: DAG::ExecuteNodeJob, args: [node.id])
    assert_equal DAG::Node::RUNNING, node.reload.state
  end
end
