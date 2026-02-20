require "test_helper"

class DAG::TranscriptRecentTurnsTest < ActiveSupport::TestCase
  test "transcript_recent_turns returns user/agent/character nodes for recent turns without tasks" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    turn_1 = "0194f3c0-0000-7000-8000-000000000100"
    turn_2 = "0194f3c0-0000-7000-8000-000000000101"

    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_input: { "content" => "u1" },
      metadata: {}
    )
    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_input: { "name" => "t1" },
      body_output: { "result" => "r1" },
      metadata: {}
    )
    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_output: { "content" => "a1" },
      metadata: {}
    )

    user_2 = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_input: { "content" => "u2" },
      metadata: {}
    )
    agent_2 = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_output: { "content" => "a2" },
      metadata: {}
    )
    character_2 = graph.nodes.create!(
      node_type: Messages::CharacterMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_output: { "content" => "c2" },
      metadata: { "actor" => "npc" }
    )

    recent = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [user_2.id, agent_2.id, character_2.id], recent.map { |n| n["node_id"] }
    assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key, Messages::CharacterMessage.node_type_key],
                 recent.map { |n| n["node_type"] }

    all_recent = graph.transcript_recent_turns(limit_turns: 2)
    assert_equal 5, all_recent.length
    assert_equal [turn_1, turn_1, turn_2, turn_2, turn_2], all_recent.map { |n| n["turn_id"] }
    assert_equal [
      Messages::UserMessage.node_type_key,
      Messages::AgentMessage.node_type_key,
      Messages::UserMessage.node_type_key,
      Messages::AgentMessage.node_type_key,
      Messages::CharacterMessage.node_type_key,
    ], all_recent.map { |n| n["node_type"] }
  end

  test "transcript_recent_turns uses NodeBody transcript_candidate? hooks for SQL prefiltering" do
    Messages.const_set(
      :CustomRecentMessage,
      Class.new(::DAG::NodeBody) do
        class << self
          def transcript_candidate?
            true
          end

          def transcript_include?(_context_node_hash)
            true
          end
        end
      end
    )

    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000150"

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_input: { "content" => "u" },
      metadata: {}
    )
    custom = graph.nodes.create!(
      node_type: "custom_recent_message",
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_output: { "content" => "x" },
      metadata: {}
    )
    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_output: { "content" => "a" },
      metadata: {}
    )

    recent = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [user.id, custom.id, agent.id], recent.map { |n| n["node_id"] }
  ensure
    Messages.send(:remove_const, :CustomRecentMessage) if Messages.const_defined?(:CustomRecentMessage, false)
  end

  test "transcript_recent_turns uses transcript_visible and transcript_preview overrides" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000200"

    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_input: { "content" => "u" },
      metadata: {}
    )

    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_output: {},
      metadata: { "transcript_visible" => true, "transcript_preview" => "(structured)" }
    )

    transcript = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key], transcript.map { |n| n["node_type"] }
    agent_hash = transcript.find { |n| n["node_id"] == agent.id }
    assert_equal "(structured)", agent_hash.dig("payload", "output_preview", "content")
  end

  test "transcript_recent_turns excludes deleted nodes by default but keeps turns visible when another anchor exists" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    turn_1 = "0194f3c0-0000-7000-8000-000000000300"
    turn_2 = "0194f3c0-0000-7000-8000-000000000301"

    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_input: { "content" => "u1" },
      metadata: {}
    )
    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_1,
      body_output: { "content" => "a1" },
      metadata: {}
    )

    deleted_user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_input: { "content" => "u2" },
      deleted_at: Time.current,
      metadata: {}
    )
    agent_2 = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_2,
      body_output: { "content" => "a2" },
      metadata: {}
    )

    recent = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [agent_2.id], recent.map { |n| n["node_id"] }
    assert_equal turn_2, recent.last.fetch("turn_id")

    recent_with_deleted = graph.transcript_recent_turns(limit_turns: 1, include_deleted: true)
    assert_includes recent_with_deleted.map { |n| n["node_id"] }, deleted_user.id
  end
end
