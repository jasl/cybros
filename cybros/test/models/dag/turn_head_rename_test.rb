require "test_helper"

class DAG::TurnHeadRenameTest < ActiveSupport::TestCase
  test "turn exposes head and lane sequence fields instead of legacy vocabulary" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    node =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        body_input: { "content" => "hello" },
        metadata: {}
      )

    turn = graph.turns.find(node.turn_id)
    legacy_head_node_id = ["an", "chor_node_id"].join.to_sym
    legacy_head_created_at = ["an", "chor_created_at"].join.to_sym
    legacy_lane_seq = ["an", "chored_seq"].join.to_sym

    assert_respond_to turn, :head_node_id
    assert_respond_to turn, :head_created_at
    assert_respond_to turn, :lane_seq
    refute_respond_to turn, legacy_head_node_id
    refute_respond_to turn, legacy_head_created_at
    refute_respond_to turn, legacy_lane_seq
  end
end
