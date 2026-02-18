require "test_helper"

class DAG::RunningLeaseReclaimerTest < ActiveSupport::TestCase
  test "reclaim! marks expired running nodes as errored" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::RUNNING,
      lease_expires_at: 1.minute.ago,
      metadata: {}
    )

    reclaimed = DAG::RunningLeaseReclaimer.reclaim!(graph: graph, now: Time.current)
    assert_equal [node.id], reclaimed

    node.reload
    assert_equal DAG::Node::ERRORED, node.state
    assert_equal "running_lease_expired", node.metadata.fetch("error")
    assert node.finished_at.present?

    assert conversation.events.exists?(
      event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
      subject: node
    )
  end
end

