require "test_helper"

class DAG::TranscriptRecentTurnsTest < ActiveSupport::TestCase
  test "transcript_recent_turns returns user/agent/character nodes for recent turns without tasks" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    turn_1 = "0194f3c0-0000-7000-8000-000000000100"
    turn_2 = "0194f3c0-0000-7000-8000-000000000101"

    user_1 =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        turn_id: turn_1,
        body_input: { "content" => "u1" },
        metadata: {}
      )
    task_1 =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        turn_id: turn_1,
        body_input: { "name" => "t1" },
        body_output: { "result" => "r1" },
        metadata: {}
      )
    agent_1 =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        turn_id: turn_1,
        body_output: { "content" => "a1" },
        metadata: {}
      )

    graph.edges.create!(from_node_id: user_1.id, to_node_id: task_1.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: task_1.id, to_node_id: agent_1.id, edge_type: DAG::Edge::SEQUENCE)

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

    graph.edges.create!(from_node_id: user_2.id, to_node_id: agent_2.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: agent_2.id, to_node_id: character_2.id, edge_type: DAG::Edge::SEQUENCE)

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

  test "transcript_recent_turns keeps task-heavy turns concise" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    turn_id = "0194f3c0-0000-7000-8000-000000000180"

    user =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        turn_id: turn_id,
        body_input: { "content" => "u" },
        metadata: {}
      )

    previous = user
    8.times do |index|
      task =
        graph.nodes.create!(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          turn_id: turn_id,
          body_input: {
            "name" => "tool_#{index}",
            "requested_name" => "tool_#{index}",
          },
          body_output: { "result" => "r#{index}" },
          metadata: {}
        )
      graph.edges.create!(from_node_id: previous.id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE)
      previous = task
    end

    agent =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        turn_id: turn_id,
        body_output: { "content" => "a" },
        metadata: {}
      )
    graph.edges.create!(from_node_id: previous.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    recent = graph.transcript_recent_turns(limit_turns: 1)

    assert_equal [user.id, agent.id], recent.map { |node| node.fetch("node_id") }
    assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key],
                 recent.map { |node| node.fetch("node_type") }
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

    conversation = create_conversation!
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

    graph.edges.create!(from_node_id: user.id, to_node_id: custom.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: custom.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    recent = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [user.id, custom.id, agent.id], recent.map { |n| n["node_id"] }

  ensure
    Messages.send(:remove_const, :CustomRecentMessage) if Messages.const_defined?(:CustomRecentMessage, false)
  end

  test "transcript_recent_turns uses transcript_visible and transcript_preview overrides" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-000000000200"

    user =
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

    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    transcript = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key], transcript.map { |n| n["node_type"] }
    agent_hash = transcript.find { |n| n["node_id"] == agent.id }
    assert_equal "(structured)", agent_hash.dig("payload", "output_preview", "content")
  end

  test "transcript_recent_turns excludes deleted nodes by default but keeps turns visible when another head exists" do
    conversation = create_conversation!
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

    user_1 = graph.nodes.find_by!(turn_id: turn_1, node_type: Messages::UserMessage.node_type_key)
    agent_1 = graph.nodes.find_by!(turn_id: turn_1, node_type: Messages::AgentMessage.node_type_key)
    graph.edges.create!(from_node_id: user_1.id, to_node_id: agent_1.id, edge_type: DAG::Edge::SEQUENCE)

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

    graph.edges.create!(from_node_id: deleted_user.id, to_node_id: agent_2.id, edge_type: DAG::Edge::SEQUENCE)

    recent = graph.transcript_recent_turns(limit_turns: 1)
    assert_equal [agent_2.id], recent.map { |n| n["node_id"] }
    assert_equal turn_2, recent.last.fetch("turn_id")

    recent_with_deleted = graph.transcript_recent_turns(limit_turns: 1, include_deleted: true)
    assert_includes recent_with_deleted.map { |n| n["node_id"] }, deleted_user.id
  end

  test "conversation transcript_recent_turns keeps task-heavy turns transcript-first" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    user = turn.fetch(:user_node)
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::RUNNING,
      lane_id: conversation.chat_lane.id,
      turn_id: agent.turn_id,
      metadata: {},
      body_input: {
        "name" => "memory_search",
        "requested_name" => "memory_search",
        "tool_call_id" => "tc_1",
        "arguments" => {},
        "arguments_summary" => "{}",
      },
    )

    transcript = conversation.transcript_recent_turns(limit_turns: 1, mode: :preview)

    assert_equal [user.id, agent.id], transcript.map { |node| node.fetch("node_id") }
    assert_equal(
      [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key],
      transcript.map { |node| node.fetch("node_type") }
    )
    assert_equal 1, transcript.last.dig("run_state", "summary", "activity_count")
  end

  test "conversation transcript_recent_turns does not require full turn execution drill-down" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::RUNNING,
      lane_id: conversation.chat_lane.id,
      turn_id: agent.turn_id,
      metadata: {},
      body_input: {
        "name" => "memory_search",
        "requested_name" => "memory_search",
        "tool_call_id" => "tc_split",
        "arguments" => {},
        "arguments_summary" => "{}",
      },
    )

    projector = Conversation::TurnExecutionProjector.new(conversation: conversation)
    projector.define_singleton_method(:turn_execution_for_turn_id) do |_turn_id|
      raise "transcript preview should not depend on full drill-down"
    end
    conversation.instance_variable_set(:@turn_execution_projector, projector)

    transcript = conversation.transcript_recent_turns(limit_turns: 1, mode: :preview)
    assert_equal [turn.fetch(:user_node).id, agent.id], transcript.map { |node| node.fetch("node_id") }
    assert_equal "running", transcript.last.dig("run_state", "status")
    assert_equal 1, transcript.last.dig("run_state", "summary", "activity_count")
  end
end
