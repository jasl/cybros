require "test_helper"

class DAG::TurnAnchorMaintenanceTest < ActiveSupport::TestCase
  test "edit replaces the turn anchor_node_id to point at the new visible anchor" do
    conversation = Conversation.create!
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
    assert_equal user.id, turn.anchor_node_id

    edited = user.edit!(new_input: { "content" => "u1 edited" })
    assert_equal DAG::Node::FINISHED, edited.state
    assert_equal turn_id, edited.turn_id

    turn = graph.turns.find(turn_id)
    assert_equal edited.id, turn.anchor_node_id

    page = lane.transcript_page(limit_turns: 10)
    assert_includes page.fetch("turn_ids"), turn_id
  end

  test "retry replaces the turn anchor_node_id when the previous anchor is archived" do
    conversation = Conversation.create!
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
    assert_equal agent.id, turn.anchor_node_id

    retried = agent.retry!
    assert_equal DAG::Node::PENDING, retried.state
    assert_equal turn_id, retried.turn_id

    turn = graph.turns.find(turn_id)
    assert_equal retried.id, turn.anchor_node_id
  end
end
