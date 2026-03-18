require "test_helper"

class SubagentThreadTest < ActiveSupport::TestCase
  test "persists durable owner and child bindings and makes child graph owner-traceable" do
    parent = create_conversation!(title: "Parent")
    owner_node = parent.append_user_message!(content: "Delegate this").fetch(:agent_node)
    owner_turn = DAG::Turn.find(owner_node.turn_id)
    child = create_child_conversation!(parent: parent)

    thread =
      SubagentThread.create!(
        build_subagent_thread_attributes(
          parent: parent,
          owner_turn: owner_turn,
          owner_node: owner_node,
          child: child,
          subagent_id: next_uuid,
        ),
      )

    resolved = SubagentThread.find_by!(child_graph_id: child.dag_graph.id)

    assert_equal thread.id, resolved.id
    assert_equal parent.id, resolved.owner_conversation_id
    assert_equal parent.dag_graph.id, resolved.owner_graph_id
    assert_equal owner_turn.id, resolved.owner_turn_id
    assert_equal owner_node.id, resolved.owner_node_id
    assert_equal child.id, resolved.child_conversation_id
    assert_equal child.dag_graph.id, resolved.child_graph_id
  end

  test "enforces one durable thread per child conversation and child graph" do
    parent = create_conversation!(title: "Parent")
    owner_node = parent.append_user_message!(content: "Delegate this").fetch(:agent_node)
    owner_turn = DAG::Turn.find(owner_node.turn_id)
    child = create_child_conversation!(parent: parent)

    SubagentThread.create!(
      build_subagent_thread_attributes(
        parent: parent,
        owner_turn: owner_turn,
        owner_node: owner_node,
        child: child,
        subagent_id: next_uuid,
      ),
    )

    duplicate =
      SubagentThread.new(
        build_subagent_thread_attributes(
          parent: parent,
          owner_turn: owner_turn,
          owner_node: owner_node,
          child: child,
          subagent_id: next_uuid,
        ),
      )

    refute duplicate.valid?
    assert_includes duplicate.errors[:child_conversation], "has already been taken"
    assert_includes duplicate.errors[:child_graph], "has already been taken"
  end

  private

    def create_child_conversation!(parent:)
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Child",
        agent: parent.agent,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        metadata: {
          "agent" => {
            "key" => "subagent:child",
            "agent_profile" => "subagent",
            "context_turns" => 50,
          },
        },
      )
    end

    def build_subagent_thread_attributes(parent:, owner_turn:, owner_node:, child:, subagent_id:)
      {
        id: subagent_id,
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
        last_snapshot: {},
        final_snapshot: {},
      }
    end

    def next_uuid
      ActiveRecord::Base.connection.select_value("select uuidv7()")
    end
end
