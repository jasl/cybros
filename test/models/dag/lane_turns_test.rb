require "test_helper"

class DAG::LaneTurnsTest < ActiveSupport::TestCase
  test "turn_count and turn_seq include compressed and soft-deleted turns" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    t1 = Time.current - 3.minutes
    t2 = Time.current - 2.minutes
    t3 = Time.current - 1.minute

    turn_1 = "0194f3c0-0000-7000-8000-00000000f001"
    turn_2 = "0194f3c0-0000-7000-8000-00000000f002"
    turn_3 = "0194f3c0-0000-7000-8000-00000000f003"

    user_1 =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_1,
        body_input: { "content" => "u1" },
        metadata: {},
        created_at: t1,
        updated_at: t1
      )
    agent_1 =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_1,
        body_output: { "content" => "a1" },
        metadata: {},
        created_at: t1 + 1.second,
        updated_at: t1 + 1.second
      )

    user_2 =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_2,
        body_input: { "content" => "u2" },
        metadata: {},
        created_at: t2,
        updated_at: t2
      )
    agent_2 =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_2,
        body_output: { "content" => "a2" },
        metadata: {},
        created_at: t2 + 1.second,
        updated_at: t2 + 1.second
      )

    user_3 =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_3,
        body_input: { "content" => "u3" },
        metadata: {},
        created_at: t3,
        updated_at: t3
      )
    agent_3 =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_3,
        body_output: { "content" => "a3" },
        metadata: {},
        created_at: t3 + 1.second,
        updated_at: t3 + 1.second
      )

    graph.edges.create!(from_node_id: user_1.id, to_node_id: agent_1.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: agent_1.id, to_node_id: user_2.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: user_2.id, to_node_id: agent_2.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: agent_2.id, to_node_id: user_3.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: user_3.id, to_node_id: agent_3.id, edge_type: DAG::Edge::SEQUENCE)

    graph.compress!(node_ids: [user_1.id, agent_1.id], summary_content: "compressed", summary_metadata: {})
    assert user_1.reload.compressed_at.present?

    user_2.soft_delete!
    assert user_2.reload.deleted_at.present?

    all_turns = lane.turn_entries
    assert_equal 3, all_turns.length
    assert_equal [turn_1, turn_2, turn_3], all_turns.map { |row| row.fetch(:turn_id) }
    assert_equal [1, 2, 3], all_turns.map { |row| row.fetch(:seq) }
    assert_equal [false, true, false], all_turns.map { |row| row.fetch(:anchor_deleted) }

    visible = lane.turn_entries(include_deleted: false)
    assert_equal [turn_1, turn_3], visible.map { |row| row.fetch(:turn_id) }
    assert_equal [1, 3], visible.map { |row| row.fetch(:seq) }

    assert_equal visible, lane.visible_turn_entries

    assert_equal 3, lane.turn_count
    assert_equal 2, lane.turn_count(include_deleted: false)

    assert_equal 1, lane.turn_seq_for(turn_1)
    assert_equal 2, lane.turn_seq_for(turn_2)
    assert_nil lane.turn_seq_for(turn_2, include_deleted: false)
  end
end
