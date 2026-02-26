require "test_helper"

class DAG::LaneMessagePaginationTest < ActiveSupport::TestCase
  test "message_page paginates transcript-candidate nodes in a lane with before/after cursors" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    t1 = Time.current - 4.minutes
    t2 = Time.current - 3.minutes
    t3 = Time.current - 2.minutes
    t4 = Time.current - 1.minute

    turn_1 = "0194f3c0-0000-7000-8000-00000000b101"
    turn_2 = "0194f3c0-0000-7000-8000-00000000b102"
    turn_3 = "0194f3c0-0000-7000-8000-00000000b103"
    turn_4 = "0194f3c0-0000-7000-8000-00000000b104"

    u1 =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c001",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_1,
        body_input: { "content" => "u1" },
        metadata: {},
        created_at: t1,
        updated_at: t1
      )
    a1 =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c002",
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_1,
        body_output: { "content" => "a1" },
        metadata: {},
        created_at: t1 + 1.second,
        updated_at: t1 + 1.second
      )
    t1_task =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c003",
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_1,
        body_input: { "name" => "t1" },
        body_output: { "result" => "r1" },
        metadata: {},
        created_at: t1 + 2.seconds,
        updated_at: t1 + 2.seconds
      )

    u2 =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c004",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_2,
        body_input: { "content" => "u2" },
        metadata: {},
        created_at: t2,
        updated_at: t2
      )
    a2 =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c005",
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_2,
        body_output: { "content" => "a2" },
        metadata: {},
        created_at: t2 + 1.second,
        updated_at: t2 + 1.second
      )

    u3 =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c006",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_3,
        body_input: { "content" => "u3" },
        metadata: {},
        created_at: t3,
        updated_at: t3
      )
    a3_empty =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c007",
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_3,
        body_output: {},
        metadata: {},
        created_at: t3 + 1.second,
        updated_at: t3 + 1.second
      )

    u4 =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c008",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_4,
        body_input: { "content" => "u4" },
        metadata: {},
        created_at: t4,
        updated_at: t4
      )
    a4 =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c009",
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_4,
        body_output: { "content" => "a4" },
        metadata: {},
        created_at: t4 + 1.second,
        updated_at: t4 + 1.second
      )

    graph.edges.create!(from_node_id: u1.id, to_node_id: t1_task.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: t1_task.id, to_node_id: a1.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: u2.id, to_node_id: a2.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: u3.id, to_node_id: a3_empty.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: u4.id, to_node_id: a4.id, edge_type: DAG::Edge::SEQUENCE)

    page = lane.message_page(limit: 3)
    assert_equal [u3.id, u4.id, a4.id], page.fetch("message_ids")

    contents =
      page.fetch("messages").map do |n|
        n.dig("payload", "input", "content").to_s.presence ||
          n.dig("payload", "output_preview", "content").to_s
      end
    assert_equal %w[u3 u4 a4], contents

    older = lane.message_page(limit: 3, before_message_id: page.fetch("before_message_id"))
    assert_equal [a1.id, u2.id, a2.id], older.fetch("message_ids")

    newer = lane.message_page(limit: 2, after_message_id: older.fetch("after_message_id"))
    assert_equal [u3.id, u4.id], newer.fetch("message_ids")

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end

  test "message_page respects include_deleted and validates cursor visibility" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000b201"
    now = Time.current

    deleted_user =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c101",
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_input: { "content" => "u" },
        deleted_at: now,
        metadata: {},
        created_at: now,
        updated_at: now
      )
    agent =
      graph.nodes.create!(
        id: "0194f3c0-0000-7000-8000-00000000c102",
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: turn_id,
        body_output: { "content" => "a" },
        metadata: {},
        created_at: now + 1.second,
        updated_at: now + 1.second
      )

    graph.edges.create!(from_node_id: deleted_user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    visible = lane.message_page(limit: 10)
    assert_equal [agent.id], visible.fetch("message_ids")

    with_deleted = lane.message_page(limit: 10, include_deleted: true)
    assert_equal [deleted_user.id, agent.id], with_deleted.fetch("message_ids")

    assert_raises(DAG::PaginationError) do
      lane.message_page(limit: 10, after_message_id: deleted_user.id)
    end

    after_deleted = lane.message_page(limit: 10, after_message_id: deleted_user.id, include_deleted: true)
    assert_equal [agent.id], after_deleted.fetch("message_ids")

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end

  test "message_page has a scanned-node safety cap (can yield an empty page when many candidates are filtered out)" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000b999"

    now = Time.current
    one_minute_ago = now - 1.minute

    user_node_id = stable_uuid(kind: 0x7100, n: 0)
    user_body_id = stable_uuid(kind: 0x7101, n: 0)

    excluded_agent_node_ids =
      2000.times.map do |i|
        stable_uuid(kind: 0x7100, n: i + 1)
      end

    body_rows = []
    node_rows = []

    body_rows << {
      id: user_body_id,
      type: "Messages::UserMessage",
      input: { "content" => "older" },
      output: {},
      output_preview: {},
      created_at: one_minute_ago,
      updated_at: one_minute_ago,
    }
    node_rows << {
      id: user_node_id,
      graph_id: graph.id,
      lane_id: lane.id,
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      metadata: {},
      turn_id: turn_id,
      body_id: user_body_id,
      created_at: one_minute_ago,
      updated_at: one_minute_ago,
      finished_at: one_minute_ago,
    }

    excluded_agent_node_ids.each_with_index do |node_id, i|
      body_id = stable_uuid(kind: 0x7102, n: i)

      body_rows << {
        id: body_id,
        type: "Messages::AgentMessage",
        input: {},
        output: {},
        output_preview: {},
        created_at: now,
        updated_at: now,
      }
      node_rows << {
        id: node_id,
        graph_id: graph.id,
        lane_id: lane.id,
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        metadata: {},
        turn_id: turn_id,
        body_id: body_id,
        created_at: now,
        updated_at: now,
        finished_at: now,
      }
    end

    DAG::Turn.insert_all!(
      [
        {
          id: turn_id,
          graph_id: graph.id,
          lane_id: lane.id,
          metadata: {},
          created_at: now,
          updated_at: now,
        },
      ]
    )
    DAG::NodeBody.insert_all!(body_rows)
    DAG::Node.insert_all!(node_rows)

    # Keep the graph realistic (older user isn't a leaf), but do not rely on leaf repair.
    DAG::Edge.insert_all!(
      [
        {
          graph_id: graph.id,
          from_node_id: user_node_id,
          to_node_id: excluded_agent_node_ids.first,
          edge_type: DAG::Edge::SEQUENCE,
          metadata: {},
          created_at: now,
          updated_at: now,
        },
      ]
    )

    page = lane.message_page(limit: 1000)

    assert_equal [], page.fetch("message_ids")
    assert_equal [], page.fetch("messages")

    older = lane.message_page(limit: 10, before_message_id: excluded_agent_node_ids.first)
    assert_equal [user_node_id], older.fetch("message_ids")
  end

  test "message_page validates cursors and limit" do
    conversation = create_conversation!
    lane = conversation.dag_graph.main_lane

    empty = lane.message_page(limit: 0)
    assert_equal [], empty.fetch("message_ids")
    assert_equal [], empty.fetch("messages")

    error =
      assert_raises(DAG::PaginationError) do
        lane.message_page(limit: "nope")
      end
    assert_equal "dag.lane.limit_must_be_an_integer", error.code

    error =
      assert_raises(DAG::PaginationError) do
        lane.message_page(limit: 1.2)
      end
    assert_equal "dag.lane.limit_must_be_an_integer", error.code

    error =
      assert_raises(DAG::PaginationError) do
        lane.message_page(limit: 10, before_message_id: "x", after_message_id: "y")
      end
    assert_includes error.message, "mutually"

    error =
      assert_raises(DAG::PaginationError) do
        lane.message_page(limit: 10, before_message_id: "0194f3c0-0000-7000-8000-00000000dead")
      end
    assert_includes error.message, "cursor"
  end

  private

    def stable_uuid(kind:, n:)
      kind = Integer(kind)
      n = Integer(n)
      raise ArgumentError, "kind must be 0..0xffff" unless kind.between?(0, 0xffff)
      raise ArgumentError, "n must be >= 0" if n.negative?

      format("00000000-0000-7000-%<kind>04x-%<n>012x", kind: kind, n: n)
    end
end
