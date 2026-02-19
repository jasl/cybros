require "test_helper"

class DAG::LaneTranscriptPaginationTest < ActiveSupport::TestCase
  test "transcript_page paginates turns in a lane with before/after cursors" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    t1 = Time.current - 4.minutes
    t2 = Time.current - 3.minutes
    t3 = Time.current - 2.minutes
    t4 = Time.current - 1.minute

    turn_1 = "0194f3c0-0000-7000-8000-00000000aa01"
    turn_2 = "0194f3c0-0000-7000-8000-00000000aa02"
    turn_3 = "0194f3c0-0000-7000-8000-00000000aa03"
    turn_4 = "0194f3c0-0000-7000-8000-00000000aa04"

    [
      [turn_1, t1, "u1", "a1"],
      [turn_2, t2, "u2", "a2"],
      [turn_3, t3, "u3", "a3"],
      [turn_4, t4, "u4", "a4"],
    ].each do |(turn_id, at, user_content, agent_content)|
      user =
        graph.nodes.create!(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          turn_id: turn_id,
          body_input: { "content" => user_content },
          metadata: {},
          created_at: at,
          updated_at: at
        )

      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_input: { "name" => "t-#{turn_id}" },
        body_output: { "result" => "r-#{turn_id}" },
        metadata: {},
        created_at: at + 1.second,
        updated_at: at + 1.second
      )

      agent =
        graph.nodes.create!(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          turn_id: turn_id,
          body_output: { "content" => agent_content },
          metadata: {},
          created_at: at + 2.seconds,
          updated_at: at + 2.seconds
        )

      graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)
    end

    page = lane.transcript_page(limit_turns: 2)
    assert_equal [turn_3, turn_4], page.fetch("turn_ids")

    transcript = page.fetch("transcript")
    assert_equal [turn_3, turn_3, turn_4, turn_4], transcript.map { |n| n.fetch("turn_id") }
    assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key] * 2,
                 transcript.map { |n| n.fetch("node_type") }

    older = lane.transcript_page(limit_turns: 2, before_turn_id: page.fetch("before_turn_id"))
    assert_equal [turn_1, turn_2], older.fetch("turn_ids")

    newer = lane.transcript_page(limit_turns: 2, after_turn_id: older.fetch("after_turn_id"))
    assert_equal [turn_3, turn_4], newer.fetch("turn_ids")
  end

  test "transcript_page validates cursors and limit" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    empty = lane.transcript_page(limit_turns: 0)
    assert_equal [], empty.fetch("turn_ids")
    assert_equal [], empty.fetch("transcript")

    error =
      assert_raises(ArgumentError) do
        lane.transcript_page(limit_turns: 10, before_turn_id: "x", after_turn_id: "y")
      end
    assert_includes error.message, "mutually"

    error =
      assert_raises(ArgumentError) do
        lane.transcript_page(limit_turns: 10, before_turn_id: "0194f3c0-0000-7000-8000-00000000dead")
      end
    assert_includes error.message, "cursor"
  end

  test "transcript_page orders turns by earliest anchor node (even with multiple anchors per turn)" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    t1 = Time.current - 2.minutes
    t2 = Time.current - 1.minute

    turn_1 = "0194f3c0-0000-7000-8000-00000000ad01"
    turn_2 = "0194f3c0-0000-7000-8000-00000000ad02"

    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_1,
      body_input: { "content" => "late" },
      metadata: {},
      created_at: t2,
      updated_at: t2
    )

    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_1,
      body_input: { "content" => "early" },
      metadata: {},
      created_at: t1,
      updated_at: t1
    )

    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_2,
      body_input: { "content" => "t2" },
      metadata: {},
      created_at: t2 + 10.seconds,
      updated_at: t2 + 10.seconds
    )

    page = lane.transcript_page(limit_turns: 1)
    assert_equal [turn_2], page.fetch("turn_ids")

    older = lane.transcript_page(limit_turns: 1, before_turn_id: page.fetch("before_turn_id"))
    assert_equal [turn_1], older.fetch("turn_ids")
  end

  test "transcript_page is lane-scoped (supports topics/subthreads)" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    main_lane = graph.main_lane

    seed_turn = "0194f3c0-0000-7000-8000-00000000ab01"

    user =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: main_lane.id,
        turn_id: seed_turn,
        body_input: { "content" => "main-u" },
        metadata: {}
      )
    agent =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: main_lane.id,
        turn_id: seed_turn,
        body_output: { "content" => "main-a" },
        metadata: {}
      )
    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    branch_root = nil

    graph.mutate! do |m|
      branch_root =
        m.fork_from!(
          from_node: agent,
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "branch-u",
          metadata: {}
        )

      branch_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "branch-a",
          metadata: {},
          turn_id: branch_root.turn_id,
          lane_id: branch_root.lane_id
        )

      m.create_edge(from_node: branch_root, to_node: branch_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    branch_lane = graph.lanes.find(branch_root.lane_id)

    main_page = main_lane.transcript_page(limit_turns: 10)
    assert_equal [seed_turn], main_page.fetch("turn_ids")
    assert_equal ["main-u", "main-a"],
                 main_page.fetch("transcript").map { |n| n.dig("payload", "input", "content").to_s.presence || n.dig("payload", "output_preview", "content").to_s }

    branch_page = branch_lane.transcript_page(limit_turns: 10)
    assert_equal [branch_root.turn_id.to_s], branch_page.fetch("turn_ids")
    assert_equal ["branch-u", "branch-a"],
                 branch_page.fetch("transcript").map { |n| n.dig("payload", "input", "content").to_s.presence || n.dig("payload", "output_preview", "content").to_s }
  end

  test "graph.transcript_page delegates to lane.transcript_page" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000ac01"

    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_id,
      body_input: { "content" => "u" },
      metadata: {}
    )
    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_id,
      body_output: { "content" => "a" },
      metadata: {}
    )

    page = graph.transcript_page(lane_id: lane.id, limit_turns: 10)
    assert_equal [turn_id], page.fetch("turn_ids")
  end
end
