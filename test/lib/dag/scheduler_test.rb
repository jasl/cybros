require "test_helper"
require "thread"

class DAG::SchedulerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    Event.delete_all
    DAG::Edge.delete_all
    DAG::Node.delete_all
    DAG::NodePayload.delete_all
    Conversation.delete_all
  end

  test "claim_executable_nodes claims pending executable nodes whose blocking parents are finished" do
    conversation = Conversation.create!

    parent = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    child = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    conversation.dag_edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    claimed = DAG::Scheduler.claim_executable_nodes(conversation_id: conversation.id, limit: 10)
    assert_equal [child.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, child.reload.state
  end

    test "claim_executable_nodes does not claim nodes blocked by non-finished parents" do
      conversation = Conversation.create!

      parent = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
      child = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
      conversation.dag_edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

      claimed = DAG::Scheduler.claim_executable_nodes(conversation_id: conversation.id, limit: 10)
      assert_equal [], claimed
      assert_equal DAG::Node::PENDING, child.reload.state
    end

    test "claim_executable_nodes claims nodes blocked only by sequence edges whose parents are terminal" do
      conversation = Conversation.create!

      parent = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::ERRORED, metadata: {})
      child = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
      conversation.dag_edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::SEQUENCE)

      claimed = DAG::Scheduler.claim_executable_nodes(conversation_id: conversation.id, limit: 10)
      assert_equal [child.id], claimed.map(&:id)
      assert_equal DAG::Node::RUNNING, child.reload.state
    end

  test "claim_executable_nodes skips locked rows" do
    conversation = Conversation.create!

    node_1 = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
    node_2 = conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    first, second = [node_1, node_2].sort_by(&:id)

    locked = Queue.new
    release = Queue.new

    locker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          DAG::Node.where(id: first.id).lock("FOR UPDATE").load
          locked << true
          release.pop
        end
      end
    end

    locked.pop

    claimed = DAG::Scheduler.claim_executable_nodes(conversation_id: conversation.id, limit: 1)
    assert_equal [second.id], claimed.map(&:id)
  ensure
    release << true
    locker.join
  end
end
