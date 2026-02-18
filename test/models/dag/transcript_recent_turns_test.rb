require "test_helper"

class DAG::TranscriptRecentTurnsTest < ActiveSupport::TestCase
  test "transcript_recent_turns returns user/agent nodes for recent turns without tasks" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    turn_1 = "0194f3c0-0000-7000-8000-000000000100"
    turn_2 = "0194f3c0-0000-7000-8000-000000000101"

    graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_input: { "content" => "u1" },
      metadata: {}
    )
    graph.nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_input: { "name" => "t1" },
      body_output: { "result" => "r1" },
      metadata: {}
    )
    graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_output: { "content" => "a1" },
      metadata: {}
    )

    user_2 = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_input: { "content" => "u2" },
      metadata: {}
    )
    agent_2 = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_output: { "content" => "a2" },
      metadata: {}
    )

    recent = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [user_2.id, agent_2.id], recent.map { |n| n["node_id"] }
    assert_equal [DAG::Node::USER_MESSAGE, DAG::Node::AGENT_MESSAGE], recent.map { |n| n["node_type"] }

    all_recent = graph.transcript_recent_turns(limit_turns: 2)
    assert_equal 4, all_recent.length
    assert_equal [turn_1, turn_1, turn_2, turn_2], all_recent.map { |n| n["turn_id"] }
    assert_equal [DAG::Node::USER_MESSAGE, DAG::Node::AGENT_MESSAGE, DAG::Node::USER_MESSAGE, DAG::Node::AGENT_MESSAGE],
                 all_recent.map { |n| n["node_type"] }
  end

  test "transcript_recent_turns uses transcript_visible and transcript_preview overrides" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000200"

    graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_input: { "content" => "u" },
      metadata: {}
    )

    agent = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_output: {},
      metadata: { "transcript_visible" => true, "transcript_preview" => "(structured)" }
    )

    transcript = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [DAG::Node::USER_MESSAGE, DAG::Node::AGENT_MESSAGE], transcript.map { |n| n["node_type"] }
    agent_hash = transcript.find { |n| n["node_id"] == agent.id }
    assert_equal "(structured)", agent_hash.dig("payload", "output_preview", "content")
  end

  test "transcript_recent_turns excludes deleted turns by default" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    turn_1 = "0194f3c0-0000-7000-8000-000000000300"
    turn_2 = "0194f3c0-0000-7000-8000-000000000301"

    graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_input: { "content" => "u1" },
      metadata: {}
    )
    graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_output: { "content" => "a1" },
      metadata: {}
    )

    deleted_user = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_input: { "content" => "u2" },
      deleted_at: Time.current,
      metadata: {}
    )
    graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_output: { "content" => "a2" },
      metadata: {}
    )

    recent = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal turn_1, recent.last.fetch("turn_id")

    recent_with_deleted = graph.transcript_recent_turns(limit_turns: 1, include_deleted: true)
    assert_includes recent_with_deleted.map { |n| n["node_id"] }, deleted_user.id
  end
end
