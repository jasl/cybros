require "test_helper"

class SubagentThreads::LifecycleSyncTest < ActiveSupport::TestCase
  test "sync_from_node! records abnormal child failure and materializes a parent-side subagent notice" do
    parent = create_conversation!(title: "Parent")
    owner_node = parent.append_user_message!(content: "Delegate this").fetch(:agent_node)
    owner_node.mark_running!
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
          "title" => "Research Agent",
          "diagnostic_level" => "debug",
        },
      )
    child_agent = thread.child_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).sole
    child_agent.mark_running!
    child_agent.mark_errored!(error: "boom")

    assert_equal "failed", thread.reload.child_status
    assert_equal "child_runtime", thread.terminal_origin
    assert_equal "boom", thread.terminal_reason
    assert thread.owner_notified_at.present?

    notice =
      parent.dag_graph.nodes.active
        .where(turn_id: owner_turn.id, node_type: Messages::Task.node_type_key)
        .order(:id)
        .to_a
        .find { |node| node.body_input["name"] == "subagent_notice" }

    refute_nil notice
    assert_equal thread.id, notice.body_input.dig("arguments", "subagent_id")
    assert_equal "failed", AgentCore::Resources::Tools::ToolResult.from_h(notice.body_output.fetch("result")).metadata.dig("subagent", "status")
  end

  test "sync_from_node! freezes active child threads once the owner turn terminalizes" do
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

    owner_node.mark_running!
    owner_node.mark_finished!(content: "done")

    assert_equal "frozen", thread.reload.status
    assert_equal "owner_turn_finished", thread.freeze_reason
    assert thread.frozen_at.present?
  end
end
