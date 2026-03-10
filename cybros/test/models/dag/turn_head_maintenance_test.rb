require "test_helper"

class DAG::TurnHeadMaintenanceTest < ActiveSupport::TestCase
  test "edit replaces the turn head_node_id to point at the new visible head" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000fa01"

    user =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_input: { "content" => "u1" },
        metadata: {}
      )
    agent =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_output: { "content" => "a1" },
        metadata: {}
      )
    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    turn = graph.turns.find(turn_id)
    assert_equal user.id, turn.head_node_id

    edited = user.edit!(new_input: { "content" => "u1 edited" })
    assert_equal DAG::Node::FINISHED, edited.state
    assert_equal turn_id, edited.turn_id

    turn = graph.turns.find(turn_id)
    assert_equal edited.id, turn.head_node_id

    page = lane.transcript_page(limit_turns: 10)
    assert_includes page.fetch("turn_ids"), turn_id
  end

  test "retry replaces the turn head_node_id when the previous head is archived" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000fa02"

    agent =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::ERRORED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_output: {},
        metadata: { "error" => "boom" }
      )

    turn = graph.turns.find(turn_id)
    assert_equal agent.id, turn.head_node_id

    retried = agent.retry!
    assert_equal DAG::Node::PENDING, retried.state
    assert_equal turn_id, retried.turn_id

    turn = graph.turns.find(turn_id)
    assert_equal retried.id, turn.head_node_id
  end

  test "edit updates head fields without perturbing execution rollup timestamps" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    turn = conversation.append_user_message!(content: "Hello")
    user = turn.fetch(:user_node)
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    tool_task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "memory_search",
          "requested_name" => "memory_search",
          "tool_call_id" => "tc_head",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )

    stream = DAG::NodeEventStream.new(node: tool_task)
    stream.activity_started!(activity_id: "task:#{tool_task.id}", activity_kind: "tool_call", phase: "execution")
    stream.activity_finished!(activity_id: "task:#{tool_task.id}", activity_kind: "tool_call", phase: "execution")
    tool_task.mark_finished!(content: "done", payload: { "activity_preview" => "done" })
    agent.mark_finished!(content: "Done")

    persisted_turn = graph.turns.find(agent.turn_id)
    original_execution_updated_at = persisted_turn.execution_updated_at
    original_execution_event_cursor = persisted_turn.execution_event_cursor

    edited = user.edit!(new_input: { "content" => "Hello again" })

    persisted_turn.reload
    assert_equal edited.id, persisted_turn.head_node_id
    assert_equal original_execution_updated_at, persisted_turn.execution_updated_at
    assert_equal original_execution_event_cursor, persisted_turn.execution_event_cursor
  end

  test "soft delete updates turn heads without recomputing execution rollups" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    user = turn.fetch(:user_node)
    agent = turn.fetch(:agent_node)
    agent.mark_finished!(content: "Done")

    refreshes = []
    original_refresh = DAG::Turn.method(:refresh_execution_rollups!)

    DAG::Turn.define_singleton_method(:refresh_execution_rollups!) do |**kwargs|
      refreshes << kwargs
      original_refresh.call(**kwargs)
    end

    user.soft_delete!

    assert_equal 0, refreshes.length
  ensure
    DAG::Turn.define_singleton_method(:refresh_execution_rollups!, original_refresh)
  end
end
