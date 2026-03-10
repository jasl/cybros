require "test_helper"

class DAG::ContextWindowAssemblyTest < ActiveSupport::TestCase
  def with_env(values)
    prior = {}
    values.each do |key, value|
      prior[key] = ENV[key]
      ENV[key] = value
    end

    yield
  ensure
    prior.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  test "context_for raises when context node hard cap is exceeded" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000d001"

    target = nil
    6.times do
      target ||= graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, turn_id: turn_id, metadata: {})
      graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, turn_id: turn_id, metadata: {})
    end

    with_env("DAG_MAX_CONTEXT_NODES" => "5") do
      assert_raises(DAG::SafetyLimits::Exceeded) do
        lane.context_for(target.id, limit_turns: 1)
      end
    end
  end

  test "context_for raises when context edge hard cap is exceeded" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000d002"

    a = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, turn_id: turn_id, metadata: {})
    b = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, turn_id: turn_id, metadata: {})
    c = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, turn_id: turn_id, metadata: {})

    graph.edges.create!(from_node: a, to_node: b, edge_type: DAG::Edge::SEQUENCE, metadata: {})
    graph.edges.create!(from_node: b, to_node: c, edge_type: DAG::Edge::SEQUENCE, metadata: {})

    with_env("DAG_MAX_CONTEXT_EDGES" => "1") do
      assert_raises(DAG::SafetyLimits::Exceeded) do
        lane.context_for(c.id, limit_turns: 1)
      end
    end
  end

  test "context_for does not count context-excluded task nodes against the cap for a task-heavy turn" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    turn = conversation.append_user_message!(content: "Hello")
    user = turn.fetch(:user_node)
    agent = turn.fetch(:agent_node)

    6.times do |index|
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane.id,
        turn_id: agent.turn_id,
        context_excluded_at: Time.current,
        metadata: {},
        body_input: {
          "name" => "tool_#{index}",
          "requested_name" => "tool_#{index}",
        },
      )
    end

    with_env("DAG_MAX_CONTEXT_NODES" => "4") do
      context = lane.context_for(agent.id, limit_turns: 1)
      assert_equal [user.id, agent.id], context.map { |node| node.fetch("node_id") }
    end
  end
end
