require "test_helper"

class TurnInternalTaskTest < ActiveSupport::TestCase
  test "exists with the expected queue associations" do
    assert Object.const_defined?(:TurnInternalTask), "Expected TurnInternalTask model to exist"

    association_names = TurnInternalTask.reflect_on_all_associations.map(&:name)

    assert_includes association_names, :conversation
    assert_includes association_names, :graph
    assert_includes association_names, :lane
    assert_includes association_names, :turn
    assert_includes association_names, :source_node
  end

  test "persists FIFO queue rows and enforces turn-scoped source idempotency" do
    assert Object.const_defined?(:TurnInternalTask), "Expected TurnInternalTask model to exist"

    conversation = create_conversation!(title: "Queue")
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    created = conversation.append_user_message!(content: "Hello")
    user_node = created.fetch(:user_node)
    turn_id = user_node.turn_id

    first =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: graph,
        lane: lane,
        turn: graph.turns.find(turn_id),
        source_node: user_node,
        turn_id: turn_id,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-1:action-0",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "researcher" },
        authored_metadata: { "source" => "test" },
        execution_mode: "parallel_safe",
        queue_position: 10,
        status: "queued",
      )
    second =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: graph,
        lane: lane,
        turn: graph.turns.find(turn_id),
        source_node: user_node,
        turn_id: turn_id,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-1:action-1",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "reviewer" },
        authored_metadata: { "source" => "test" },
        execution_mode: "parallel_safe",
        queue_position: 20,
        status: "queued",
      )

    assert_equal [first.id, second.id], TurnInternalTask.where(turn_id: turn_id).ordered.pluck(:id)

    duplicate =
      TurnInternalTask.new(
        conversation: conversation,
        graph: graph,
        lane: lane,
        turn: graph.turns.find(turn_id),
        source_node: user_node,
        turn_id: turn_id,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-1:action-0",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "duplicate" },
        authored_metadata: {},
        execution_mode: "parallel_safe",
        queue_position: 30,
        status: "queued",
      )

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:source_fingerprint], "has already been taken"
  end

  test "requires the lane to be attached to the owning conversation" do
    root = create_conversation!(title: "Root")
    created = root.append_user_message!(content: "Hello")
    source_node = created.fetch(:user_node)
    foreign_lane =
      root.dag_graph.lanes.create!(
        role: DAG::Lane::BRANCH,
        metadata: {},
      )

    row =
      TurnInternalTask.new(
        conversation: root,
        graph: root.dag_graph,
        lane: foreign_lane,
        turn: root.dag_graph.turns.find(source_node.turn_id),
        turn_id: source_node.turn_id,
        source_node: source_node,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-lane-mismatch",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "wrong-lane" },
        authored_metadata: {},
        execution_mode: "serial",
        queue_position: 10,
        status: "queued",
      )

    refute_predicate row, :valid?
    assert_includes row.errors[:lane], "must be attached to the owning conversation"
  end

  test "requires source node and turn to match the selected lane while allowing lifecycle without a materialized DAG node" do
    conversation = create_conversation!(title: "Queue validation")
    first = conversation.append_user_message!(content: "Hello")

    first_user = first.fetch(:user_node)
    first_turn = conversation.dag_graph.turns.find(first_user.turn_id)
    alternate_lane =
      conversation.dag_graph.lanes.create!(
        role: DAG::Lane::BRANCH,
        metadata: {},
      )
    alternate_turn = conversation.dag_graph.turns.create!(lane: alternate_lane, metadata: {})
    alternate_source =
      conversation.dag_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane: alternate_lane,
        turn: alternate_turn,
        metadata: {},
      )

    row =
      TurnInternalTask.new(
        conversation: conversation,
        graph: conversation.dag_graph,
        lane: conversation.chat_lane,
        turn: first_turn,
        turn_id: first_turn.id,
        source_node: alternate_source,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-turn-mismatch",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "mismatch" },
        authored_metadata: {},
        execution_mode: "serial",
        queue_position: 10,
        status: "queued",
      )

    refute_predicate row, :valid?
    assert_includes row.errors[:source_node], "must belong to the selected turn and lane"

    valid =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: conversation.dag_graph,
        lane: conversation.chat_lane,
        turn: first_turn,
        turn_id: first_turn.id,
        source_node: first_user,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-turn-match",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "ok" },
        authored_metadata: {},
        execution_mode: "serial",
        queue_position: 20,
        status: "queued",
      )

    assert_nil valid.materialized_task_node_id
  end

  test "database constrains status and execution mode" do
    conversation = create_conversation!(title: "Queue constraints")
    created = conversation.append_user_message!(content: "Hello")
    user_node = created.fetch(:user_node)
    turn = conversation.dag_graph.turns.find(user_node.turn_id)

    row =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: conversation.dag_graph,
        lane: conversation.chat_lane,
        turn: turn,
        turn_id: turn.id,
        source_node: user_node,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-db-constraints",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "ok" },
        authored_metadata: {},
        execution_mode: "serial",
        queue_position: 10,
        status: "queued",
      )

    assert_raises(ActiveRecord::StatementInvalid) do
      row.update_column(:status, "bogus")
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      row.update_column(:execution_mode, "bogus")
    end
  end

  test "builds a normalized operation envelope from input and authored metadata" do
    conversation = create_conversation!(title: "Queue envelope")
    created = conversation.append_user_message!(content: "Hello")
    user_node = created.fetch(:user_node)
    turn = conversation.dag_graph.turns.find(user_node.turn_id)

    row =
      TurnInternalTask.create!(
        conversation: conversation,
        graph: conversation.dag_graph,
        lane: conversation.chat_lane,
        turn: turn,
        turn_id: turn.id,
        source_node: user_node,
        source_hook_name: "agent_message_tool_loop",
        source_fingerprint: "direct-tool:tc_env",
        logical_tool_name: "search",
        input: {
          tool_call_id: "tc_env",
          arguments: {
            query: "TODO",
          },
        },
        authored_metadata: {
          origin: "bootstrap_proposal",
          reason: "inspect repo state",
          approval_hint: {
            mode: "confirm",
          },
          idempotency_key: "bootstrap.search",
          sequence_id: "opseq_fixture",
          step_index: 0,
          step_count: 2,
        },
        execution_mode: "serial",
        queue_position: 10,
        status: "queued",
      )

    assert_equal(
      {
        "tool_call_id" => "tc_env",
        "logical_tool_name" => "search",
        "arguments" => { "query" => "TODO" },
        "reason" => "inspect repo state",
        "origin" => "bootstrap_proposal",
        "approval_hint" => { "mode" => "confirm" },
        "idempotency_key" => "bootstrap.search",
        "sequence_id" => "opseq_fixture",
        "step_index" => 0,
        "step_count" => 2,
      },
      row.operation_envelope,
    )
  end

  test "requires any materialized task node to belong to the selected graph" do
    conversation = create_conversation!(title: "Queue materialized node")
    created = conversation.append_user_message!(content: "Hello")
    user_node = created.fetch(:user_node)
    turn = conversation.dag_graph.turns.find(user_node.turn_id)

    other = create_conversation!(title: "Other")
    foreign_task =
      other.dag_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::PENDING,
        metadata: {},
      )

    row =
      TurnInternalTask.new(
        conversation: conversation,
        graph: conversation.dag_graph,
        lane: conversation.chat_lane,
        turn: turn,
        source_node: user_node,
        materialized_task_node: foreign_task,
        source_hook_name: "after_task_notice",
        source_fingerprint: "notice-materialized-node-mismatch",
        logical_tool_name: "subagent_spawn",
        input: { "name" => "ok" },
        authored_metadata: {},
        execution_mode: "serial",
        queue_position: 10,
        status: "queued",
      )

    refute_predicate row, :valid?
    assert_includes row.errors[:materialized_task_node], "must belong to the selected graph"
  end
end
