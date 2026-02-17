require "test_helper"
require "thread"

class DAG::TickGraphJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  teardown do
    Event.delete_all
    DAG::Edge.delete_all
    DAG::Node.delete_all
    DAG::NodePayload.delete_all
    DAG::Graph.delete_all
    Conversation.delete_all
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "tick claims executable nodes and enqueues execute jobs" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    DAG::TickGraphJob.perform_now(graph.id, limit: 10)

    assert_enqueued_with(job: DAG::ExecuteNodeJob, args: [node.id])
    assert_equal DAG::Node::RUNNING, node.reload.state
  end

  test "tick is a no-op when the advisory lock is already held" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    locked = Queue.new
    release = Queue.new

    lock_name = graph.advisory_lock_name

    holder = Thread.new do
      DAG::Graph.with_advisory_lock(lock_name) do
        locked << true
        release.pop
      end
    end

    locked.pop

    assert_no_enqueued_jobs do
      DAG::TickGraphJob.perform_now(graph.id, limit: 10)
    end
    assert_equal DAG::Node::PENDING, node.reload.state
  ensure
    release << true
    holder.join
  end
end
