require "test_helper"

class SubagentThreads::ControlPlaneTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "spawn! creates a durable thread with child graph owner tracing" do
    parent = create_conversation!(title: "Parent")
    owner_node = parent.append_user_message!(content: "Delegate this").fetch(:agent_node)
    owner_turn = DAG::Turn.find(owner_node.turn_id)

    thread =
      SubagentThreads::ControlPlane.spawn!(
        parent: parent,
        owner_graph: parent.dag_graph,
        owner_turn: owner_turn,
        owner_node: owner_node,
        request: {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
          "context_turns" => 50,
          "title" => "Child",
          "diagnostic_level" => "standard",
        },
      )

    assert_equal parent.id, thread.owner_conversation_id
    assert_equal parent.dag_graph.id, thread.owner_graph_id
    assert_equal owner_turn.id, thread.owner_turn_id
    assert_equal owner_node.id, thread.owner_node_id
    assert_equal thread.child_conversation.dag_graph.id, thread.child_graph_id
  end

  test "poll! resolves ownership through the thread row instead of child metadata" do
    parent = create_conversation!(title: "Parent")
    owner_node = parent.append_user_message!(content: "Delegate this").fetch(:agent_node)
    owner_turn = DAG::Turn.find(owner_node.turn_id)
    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Child",
        agent: parent.agent,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        metadata: { "agent" => { "agent_profile" => "subagent" } },
      )

    thread =
      SubagentThread.create!(
        id: ActiveRecord::Base.connection.select_value("select uuidv7()"),
        owner_conversation: parent,
        owner_graph: parent.dag_graph,
        owner_turn: owner_turn,
        owner_node: owner_node,
        child_conversation: child,
        child_graph: child.dag_graph,
        requested_name: "child",
        title: "Child",
        agent_profile: "subagent",
        context_turns: 50,
        diagnostic_level: "standard",
        status: "active",
        child_status: "pending",
        depth: 1,
        last_snapshot: { "ok" => true, "subagent_id" => nil, "status" => "pending", "counts" => { "pending" => 1, "running" => 0, "awaiting_approval" => 0 } },
        final_snapshot: {},
      )

    child.update!(
      metadata: child.metadata.merge(
        "subagent_thread_id" => thread.id,
        "owner_conversation_id" => parent.id,
        "owner_graph_id" => parent.dag_graph.id,
        "owner_turn_id" => owner_turn.id,
        "owner_node_id" => owner_node.id,
      ),
    )

    snapshot =
      SubagentThreads::ControlPlane.poll!(
        subagent_id: thread.id,
        parent: parent,
        parent_graph: parent.dag_graph,
        limit_turns: 10,
      )

    assert_equal thread.id, snapshot.fetch("subagent_id")
    assert_equal "pending", snapshot.fetch("status")
  end

  test "send_input! proxies a new child turn through the owner while direct child mutation stays blocked" do
    parent = create_conversation!(title: "Parent")
    owner_node = parent.append_user_message!(content: "Delegate this").fetch(:agent_node)
    owner_turn = DAG::Turn.find(owner_node.turn_id)
    thread =
      SubagentThreads::ControlPlane.spawn!(
        parent: parent,
        owner_graph: parent.dag_graph,
        owner_turn: owner_turn,
        owner_node: owner_node,
        request: {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
          "context_turns" => 50,
          "title" => "Child",
          "diagnostic_level" => "standard",
        },
      )
    child = thread.child_conversation

    error = assert_raises(Cybros::Error) { child.append_user_message!(content: "direct child input") }
    assert_equal "managed_subagent_read_only", error.message

    snapshot =
      SubagentThreads::ControlPlane.send_input!(
        subagent_id: thread.id,
        parent: parent,
        parent_graph: parent.dag_graph,
        parent_turn: owner_turn,
        input: "owner follow up",
      )

    assert_equal "send_input", snapshot.fetch("operation")
    assert_equal thread.id, snapshot.fetch("subagent_id")
    assert_includes child.reload.transcript_recent_turns(limit_turns: 5).map { |message| message.dig("payload", "input", "content").to_s }, "owner follow up"
  end

  test "close! stops active child work and terminally closes the control plane without owner notice" do
    parent = create_conversation!(title: "Parent")
    owner_node = parent.append_user_message!(content: "Delegate this").fetch(:agent_node)
    owner_turn = DAG::Turn.find(owner_node.turn_id)
    thread =
      SubagentThreads::ControlPlane.spawn!(
        parent: parent,
        owner_graph: parent.dag_graph,
        owner_turn: owner_turn,
        owner_node: owner_node,
        request: {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
          "context_turns" => 50,
          "title" => "Child",
          "diagnostic_level" => "standard",
        },
      )
    child_agent = thread.child_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).sole
    child_agent.mark_running!

    snapshot =
      SubagentThreads::ControlPlane.close!(
        subagent_id: thread.id,
        parent: parent,
        parent_graph: parent.dag_graph,
        parent_turn: owner_turn,
      )

    assert_equal "close", snapshot.fetch("operation")
    assert_equal "closed", thread.reload.status
    assert_equal "owner_action", thread.terminal_origin
    assert_equal "closed", thread.terminal_reason
    assert_nil thread.owner_notified_at
    assert_equal DAG::Node::STOPPED, child_agent.reload.state
  end

  test "send_input! rejects callers from a different parent turn in the same conversation" do
    parent = create_conversation!(title: "Parent")
    owner_turn_payload = parent.append_user_message!(content: "Delegate this")
    owner_node = owner_turn_payload.fetch(:agent_node)
    owner_turn = DAG::Turn.find(owner_node.turn_id)
    thread =
      SubagentThreads::ControlPlane.spawn!(
        parent: parent,
        owner_graph: parent.dag_graph,
        owner_turn: owner_turn,
        owner_node: owner_node,
        request: {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
          "context_turns" => 50,
          "title" => "Child",
          "diagnostic_level" => "standard",
        },
      )

    other_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    parent.dag_graph.mutate!(turn_id: other_turn_id) do |m|
      m.create_node(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        content: "Different turn",
        metadata: {},
      )
    end

    other_turn = DAG::Turn.find(other_turn_id)

    error =
      assert_raises(AgentCore::ValidationError) do
        SubagentThreads::ControlPlane.send_input!(
          subagent_id: thread.id,
          parent: parent,
          parent_graph: parent.dag_graph,
          parent_turn: other_turn,
          input: "owner follow up",
        )
      end

    assert_equal "cybros.subagent.subagent_not_owned_by_turn", error.code
  end
end
