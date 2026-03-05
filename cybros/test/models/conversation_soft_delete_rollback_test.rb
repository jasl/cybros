require "test_helper"

class ConversationSoftDeleteRollbackTest < ActiveSupport::TestCase
  test "soft_delete_node! refuses to delete a fork point node" do
    conversation = create_conversation!(title: "Root")

    result = conversation.append_user_message!(content: "Hello")
    agent = result.fetch(:agent_node)
    agent.mark_running!
    agent.mark_finished!(content: "Hi")

    _branch =
      conversation.create_child!(
        from_node_id: agent.id,
        kind: "branch",
        title: "Branch",
        user_content: "What if?"
      )

    assert_raises(Cybros::Error) do
      conversation.soft_delete_node!(node_id: agent.id)
    end
  end

  test "soft_delete_node! on the current trigger message stops downstream pending work and cancels its runs" do
    conversation = create_conversation!(title: "Chat")

    t1 = conversation.append_user_message!(content: "t1")
    agent1 = t1.fetch(:agent_node)
    agent1.mark_running!
    agent1.mark_finished!(content: "a1")

    t2 = conversation.append_user_message!(content: "t2")
    user2 = t2.fetch(:user_node)
    agent2 = t2.fetch(:agent_node)

    run2 = ConversationRun.order(:id).last
    assert_equal agent2.id, run2.dag_node_id
    assert_equal "queued", run2.state
    assert_equal DAG::Node::PENDING, agent2.state

    conversation.soft_delete_node!(node_id: user2.id)

    assert_equal DAG::Node::STOPPED, agent2.reload.state
    assert_equal "canceled", run2.reload.state
  end

  test "soft_delete_node! on a non-tail/non-trigger message does not stop current downstream work" do
    conversation = create_conversation!(title: "Chat")

    t1 = conversation.append_user_message!(content: "t1")
    user1 = t1.fetch(:user_node)
    agent1 = t1.fetch(:agent_node)
    agent1.mark_running!
    agent1.mark_finished!(content: "a1")

    t2 = conversation.append_user_message!(content: "t2")
    agent2 = t2.fetch(:agent_node)

    run2 = ConversationRun.order(:id).last
    assert_equal "queued", run2.state
    assert_equal DAG::Node::PENDING, agent2.state

    conversation.soft_delete_node!(node_id: user1.id)

    assert_equal DAG::Node::PENDING, agent2.reload.state
    assert_equal "queued", run2.reload.state
  end

  test "soft_delete_node! stops and immediately deletes the current pending head node when graph is idle" do
    conversation = create_conversation!(title: "Chat")

    result = conversation.append_user_message!(content: "Hello")
    agent = result.fetch(:agent_node)
    run = ConversationRun.order(:id).last

    assert_equal DAG::Node::PENDING, agent.state
    assert_equal "queued", run.state

    conversation.soft_delete_node!(node_id: agent.id)

    agent.reload
    assert_equal DAG::Node::STOPPED, agent.state
    assert agent.deleted?
    assert_nil DAG::NodeVisibilityPatch.find_by(graph_id: agent.graph_id, node_id: agent.id), "expected no deferred patch when delete can be applied immediately"
    assert_equal "canceled", run.reload.state
  end

  test "soft_delete_node! stops downstream running work and cancels its running run" do
    conversation = create_conversation!(title: "Chat")

    t1 = conversation.append_user_message!(content: "t1")
    agent1 = t1.fetch(:agent_node)
    agent1.mark_running!
    agent1.mark_finished!(content: "a1")

    t2 = conversation.append_user_message!(content: "t2")
    user2 = t2.fetch(:user_node)
    agent2 = t2.fetch(:agent_node)
    run2 = ConversationRun.order(:id).last

    run2.mark_running!
    agent2.mark_running!
    assert_equal "running", run2.reload.state
    assert_equal DAG::Node::RUNNING, agent2.reload.state

    conversation.soft_delete_node!(node_id: user2.id)

    assert_equal DAG::Node::STOPPED, agent2.reload.state
    assert_equal "canceled", run2.reload.state
  end

  test "soft_delete_node! rollback does not stop pending work on other lanes (child conversations)" do
    root = create_conversation!(title: "Root")
    graph = root.root_graph

    # Root turn 1 (terminal agent to fork from)
    t1 = root.append_user_message!(content: "t1")
    agent1 = t1.fetch(:agent_node)
    agent1.mark_running!
    agent1.mark_finished!(content: "a1")

    branch = root.create_child!(from_node_id: agent1.id, kind: "branch", title: "Branch", user_content: "what if")

    # Branch has its own pending agent + run.
    branch_turn = branch.append_user_message!(content: "branch msg")
    branch_agent = branch_turn.fetch(:agent_node)
    branch_run = ConversationRun.order(:id).last
    assert_equal branch.id, branch_run.conversation_id
    assert_equal branch_agent.id, branch_run.dag_node_id
    assert_equal DAG::Node::PENDING, branch_agent.state

    # Root turn 2 (pending head)
    root_turn = root.append_user_message!(content: "root msg")
    root_user2 = root_turn.fetch(:user_node)
    root_agent2 = root_turn.fetch(:agent_node)
    root_run2 = ConversationRun.order(:id).last

    assert_equal root.id, root_run2.conversation_id
    assert_equal root_agent2.id, root_run2.dag_node_id
    assert_equal DAG::Node::PENDING, root_agent2.state

    # Deleting the current trigger should rollback the root head, but must not touch the branch lane.
    root.soft_delete_node!(node_id: root_user2.id)

    assert_equal DAG::Node::PENDING, branch_agent.reload.state
    assert_equal "queued", branch_run.reload.state
  end

  test "soft_delete_node! refuses to delete task nodes" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    task = nil
    graph.mutate! do |m|
      task =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          metadata: {},
        )
    end
    assert task

    error = assert_raises(Cybros::Error) { conversation.soft_delete_node!(node_id: task.id) }
    assert_match(/task/i, error.message)
  end

  test "soft_delete_node! does not crash when node body is missing (treat as not deletable)" do
    conversation = create_conversation!(title: "Chat")
    result = conversation.append_user_message!(content: "Hello")
    agent = result.fetch(:agent_node)

    orig_node_body = DAG::Node.instance_method(:body)
    orig_body_class_for = DAG::Graph.instance_method(:body_class_for_node_type)

    DAG::Node.define_method(:body) { nil }
    DAG::Graph.define_method(:body_class_for_node_type) { |_node_type| raise KeyError }

    assert_raises(Cybros::Error) { conversation.soft_delete_node!(node_id: agent.id) }
  ensure
    DAG::Node.define_method(:body, orig_node_body) if orig_node_body
    DAG::Graph.define_method(:body_class_for_node_type, orig_body_class_for) if orig_body_class_for
  end
end
