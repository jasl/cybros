require "test_helper"

class SubagentThreads::OwnerFinalizerTest < ActiveSupport::TestCase
  test "freeze_active_threads! freezes active child threads when the owner turn finalizes" do
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
        child_status: "running",
        depth: 1,
        last_snapshot: { "ok" => true, "subagent_id" => nil, "status" => "running" },
        final_snapshot: {},
      )

    SubagentThreads::OwnerFinalizer.freeze_active_threads!(
      owner_turn: owner_turn,
      freeze_reason: "owner_turn_finished",
    )

    assert_equal "frozen", thread.reload.status
    assert_equal "owner_turn_finished", thread.freeze_reason
    assert thread.frozen_at.present?
  end
end
