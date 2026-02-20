require "test_helper"

class DAG::TurnMessageHelpersTest < ActiveSupport::TestCase
  test "message_nodes projection determines end_message_node_id" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000b301"
    t = Time.current - 1.minute

    user =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c201",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_input: { "content" => "u" },
        metadata: {},
        created_at: t,
        updated_at: t
      )

    graph.nodes.create!(
      id: "0194f3c0-0000-7000-8000-00000000c202",
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_id,
      body_output: {},
      metadata: {},
      created_at: t + 1.second,
      updated_at: t + 1.second
    )

    turn = graph.turns.find(turn_id)

    assert_equal user.id, turn.start_message_node_id
    assert_equal [user.id], turn.message_nodes.map { |n| n.fetch("node_id") }
    assert_equal user.id, turn.end_message_node_id
  end

  test "running agent_message is included and becomes the end message" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000b302"
    t = Time.current - 1.minute

    user =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c203",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_input: { "content" => "u" },
        metadata: {},
        created_at: t,
        updated_at: t
      )

    agent =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c204",
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: lane.id,
        turn_id: turn_id,
        body_output: {},
        metadata: {},
        created_at: t + 1.second,
        updated_at: t + 1.second
      )

    turn = graph.turns.find(turn_id)

    assert_equal user.id, turn.start_message_node_id
    assert_equal [user.id, agent.id], turn.message_nodes.map { |n| n.fetch("node_id") }
    assert_equal agent.id, turn.end_message_node_id
  end

  test "include_deleted affects start_message_node_id and message_nodes visibility" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000b303"
    t = Time.current - 1.minute

    deleted_user =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c205",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_input: { "content" => "u" },
        deleted_at: t,
        metadata: {},
        created_at: t,
        updated_at: t
      )

    agent =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c206",
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_output: { "content" => "a" },
        metadata: {},
        created_at: t + 1.second,
        updated_at: t + 1.second
      )

    turn = graph.turns.find(turn_id)

    assert_equal agent.id, turn.start_message_node_id
    assert_equal deleted_user.id, turn.start_message_node_id(include_deleted: true)

    assert_equal [agent.id], turn.message_nodes.map { |n| n.fetch("node_id") }
    assert_equal [deleted_user.id, agent.id], turn.message_nodes(include_deleted: true).map { |n| n.fetch("node_id") }

    assert_equal agent.id, turn.end_message_node_id
    assert_equal agent.id, turn.end_message_node_id(include_deleted: true)
  end
end
