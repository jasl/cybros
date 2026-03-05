require "test_helper"

class DAG::MultiBranchLargeConversationTest < ActiveSupport::TestCase
  test "message_page and context_for stay bounded on 200 turns with multiple branches" do
    conversation = create_conversation!(title: "Perf")
    graph = conversation.dag_graph
    main_lane = conversation.chat_lane

    # Build 200 turns on main lane.
    last_agent = nil
    200.times do |i|
      turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
      graph.mutate!(turn_id: turn_id) do |m|
        user =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: main_lane.id,
            content: "u#{i}",
            metadata: {},
          )

        agent =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: main_lane.id,
            metadata: {},
          )

        m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
        last_agent = agent
      end
    end

    assert last_agent

    # Create a few branches from earlier points.
    branch_lanes = []
    graph.nodes.active.where(lane_id: main_lane.id, node_type: Messages::AgentMessage.node_type_key).order(:id).limit(5).each_with_index do |agent, idx|
      child = conversation.create_child!(from_node_id: agent.id, kind: "branch", title: "B#{idx}", user_content: "branch")
      branch_lane = child.chat_lane
      branch_lanes << branch_lane

      # Add 20 turns to each branch.
      20.times do |j|
        t = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
        graph.mutate!(turn_id: t) do |m|
          u =
            m.create_node(
              node_type: Messages::UserMessage.node_type_key,
              state: DAG::Node::FINISHED,
              lane_id: branch_lane.id,
              content: "b#{idx}-u#{j}",
              metadata: {},
            )
          a =
            m.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: DAG::Node::FINISHED,
              lane_id: branch_lane.id,
              metadata: {},
            )
          m.create_edge(from_node: u, to_node: a, edge_type: DAG::Edge::SEQUENCE)
        end
      end
    end

    lanes = [main_lane] + branch_lanes
    lanes.each do |lane|
      page = lane.message_page(limit: 30, mode: :preview)
      assert page.fetch("message_ids").length <= 30

      head = graph.nodes.active.where(lane_id: lane.id, node_type: Messages::AgentMessage.node_type_key).order(:id).last
      assert head
      context = lane.context_for(head.id, limit_turns: 50, mode: :preview, include_excluded: false, include_deleted: false)
      assert context.any?
    end
  end
end
