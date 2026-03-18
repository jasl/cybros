require "test_helper"

class LaneProcessTest < ActiveSupport::TestCase
  test "requires conversation lane status and started_by_type" do
    lane_process = LaneProcess.new

    assert_not lane_process.valid?
    assert_includes lane_process.errors.attribute_names, :conversation
    assert_includes lane_process.errors.attribute_names, :lane
    assert_includes lane_process.errors.attribute_names, :status
    assert_includes lane_process.errors.attribute_names, :started_by_type
  end

  test "active and terminal helpers reflect status" do
    conversation = create_conversation!
    lane = conversation.chat_lane

    running = LaneProcess.new(conversation: conversation, lane: lane, status: "running", started_by_type: "agent")
    lost = LaneProcess.new(conversation: conversation, lane: lane, status: "lost", started_by_type: "agent")

    assert_predicate running, :active?
    assert_not running.terminal?

    assert_not lost.active?
    assert_predicate lost, :terminal?
  end

  test "allows branch lanes from the same conversation graph" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    branch_lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: conversation.chat_lane.id, metadata: {})

    lane_process =
      LaneProcess.new(
        conversation: conversation,
        lane: branch_lane,
        status: "running",
        started_by_type: "agent",
      )

    assert_predicate lane_process, :valid?
  end

  test "rejects lanes from a different conversation graph" do
    conversation = create_conversation!
    other_conversation = create_conversation!

    lane_process =
      LaneProcess.new(
        conversation: conversation,
        lane: other_conversation.chat_lane,
        status: "running",
        started_by_type: "agent",
      )

    assert_not lane_process.valid?
    assert_includes lane_process.errors[:lane], "must belong to the conversation graph"
  end
end
