require "test_helper"
require "thread"

class DAG::TickGraphJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  teardown do
    ActiveRecord::Base.lease_connection.disable_referential_integrity do
      RunDraft.delete_all
      Event.delete_all
      ConversationRun.delete_all
      DAG::Edge.delete_all
      DAG::Node.delete_all
      DAG::NodeBody.delete_all
      DAG::Graph.delete_all
      Conversation.delete_all
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "tick claims executable nodes and enqueues execute jobs" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

    DAG::TickGraphJob.perform_now(graph.id, limit: 10)

    assert_enqueued_with(job: DAG::ExecuteNodeJob, args: [node.id])
    assert_equal DAG::Node::RUNNING, node.reload.state
  end

  test "tick is a no-op when the advisory lock is already held" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

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

  test "tick reschedules itself for the earliest delayed pending node" do
    travel_to(Time.zone.parse("2026-03-07 10:00:00")) do
      conversation = create_conversation!
      graph = conversation.dag_graph
      parent = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
      delayed_time = 1.5.seconds.from_now
      delayed =
        graph.nodes.create!(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
          claim_after_at: delayed_time,
        )
      graph.edges.create!(from_node_id: parent.id, to_node_id: delayed.id, edge_type: DAG::Edge::DEPENDENCY)

      DAG::TickGraphJob.perform_now(graph.id, limit: 10)

      matching =
        enqueued_jobs.find do |job|
          job[:job] == DAG::TickGraphJob &&
            Array(job[:args]).first == graph.id &&
            job[:at].present?
        end

      assert matching, "expected a delayed tick to be enqueued"
      assert_in_delta delayed_time.to_f, matching[:at].to_f, 0.05
    end
  end
end
