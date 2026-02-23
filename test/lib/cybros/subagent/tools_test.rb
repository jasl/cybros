# frozen_string_literal: true

require "test_helper"

class Cybros::Subagent::ToolsTest < ActiveSupport::TestCase
  def spawn_tool
    @spawn_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_spawn" }
  end

  def poll_tool
    @poll_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_poll" }
  end

  test "subagent_spawn creates child conversation and seeds a minimal executable turn" do
    parent =
      Conversation.create!(
        metadata: {
          "agent" => {
            "agent_profile" => "review",
            "context_turns" => 88,
          },
        },
      )

    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    from_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )
    end

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: from_node.id.to_s,
            lane_id: from_node.lane_id.to_s,
            turn_id: from_node.turn_id.to_s,
          },
          agent: {
            key: "main",
            agent_profile: "review",
            context_turns: 77,
          },
        },
      )

    result = spawn_tool.call({ "name" => "My Agent", "prompt" => "child: hello" }, context: ctx)
    refute result.error?, result.text

    payload = JSON.parse(result.text)
    assert_equal true, payload.fetch("ok")
    assert_equal "spawned", payload.fetch("status")

    child = Conversation.find(payload.fetch("child_conversation_id"))

    assert_equal "subagent:my_agent", child.metadata.dig("agent", "key")
    assert_equal "review", child.metadata.dig("agent", "agent_profile")
    assert_equal 77, child.metadata.dig("agent", "context_turns")
    assert_equal parent.id.to_s, child.metadata.dig("subagent", "parent_conversation_id")
    assert_equal graph.id.to_s, child.metadata.dig("subagent", "parent_graph_id")
    assert_equal from_node.id.to_s, child.metadata.dig("subagent", "spawned_from_node_id")

    child_graph = child.dag_graph
    user = child_graph.nodes.active.where(node_type: Messages::UserMessage.node_type_key).sole
    agent = child_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).sole

    assert_equal DAG::Node::PENDING, agent.state
    assert_equal user.turn_id, agent.turn_id

    assert child_graph.edges.active.where(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE).exists?
  end

  test "subagent_spawn rejects nested spawns" do
    parent = Conversation.create!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    from_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )
    end

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: from_node.id.to_s,
            lane_id: from_node.lane_id.to_s,
            turn_id: from_node.turn_id.to_s,
          },
          agent: {
            key: "subagent:child",
            agent_profile: "coding",
            context_turns: 50,
          },
        },
      )

    assert_no_difference -> { Conversation.count } do
      result = spawn_tool.call({ "name" => "nested", "prompt" => "hi" }, context: ctx)
      assert result.error?
      assert_includes result.text, "nested subagent_spawn is not allowed"
    end

    ctx2 = ctx.with(attributes: ctx.attributes.merge(agent: ctx.attributes.fetch(:agent).merge(key: "subagent")))

    assert_no_difference -> { Conversation.count } do
      result = spawn_tool.call({ "name" => "nested", "prompt" => "hi" }, context: ctx2)
      assert result.error?
      assert_includes result.text, "nested subagent_spawn is not allowed"
    end
  end

  test "subagent_spawn rejects invalid context_turns" do
    parent = Conversation.create!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    from_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )
    end

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: from_node.id.to_s,
            lane_id: from_node.lane_id.to_s,
            turn_id: from_node.turn_id.to_s,
          },
          agent: { key: "main", agent_profile: "coding", context_turns: 50 },
        },
      )

    assert_no_difference -> { Conversation.count } do
      result = spawn_tool.call({ "name" => "child", "prompt" => "hi", "context_turns" => "abc" }, context: ctx)
      assert result.error?
      assert_includes result.text, "validation failed"
      assert_equal "cybros.subagent_spawn.context_turns_must_be_an_integer", result.metadata.dig(:validation_error, :code)
    end
  end

  test "subagent_spawn rejects invalid agent_profile" do
    parent = Conversation.create!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    from_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )
    end

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: from_node.id.to_s,
            lane_id: from_node.lane_id.to_s,
            turn_id: from_node.turn_id.to_s,
          },
          agent: { key: "main", agent_profile: "coding", context_turns: 50 },
        },
      )

    assert_no_difference -> { Conversation.count } do
      result = spawn_tool.call({ "name" => "child", "prompt" => "hi", "agent_profile" => "wat" }, context: ctx)
      assert result.error?
      assert_includes result.text, "validation failed"
      assert_equal "cybros.subagent_spawn.invalid_agent_profile", result.metadata.dig(:validation_error, :code)
    end
  end

  test "subagent_poll returns missing status when child does not exist" do
    result = poll_tool.call({ "child_conversation_id" => "0194f3c0-0000-7000-8000-00000000ffff" }, context: nil)
    refute result.error?, result.text

    payload = JSON.parse(result.text)
    assert_equal "missing", payload.fetch("status")
    assert_equal [], payload.fetch("transcript_lines")
  end

  test "subagent_poll rejects invalid limit_turns when provided" do
    result = poll_tool.call({ "child_conversation_id" => "0194f3c0-0000-7000-8000-00000000ffff", "limit_turns" => "abc" }, context: nil)
    assert result.error?
    assert_includes result.text, "validation failed"
    assert_equal "cybros.subagent_poll.limit_turns_must_be_an_integer", result.metadata.dig(:validation_error, :code)
  end

  test "subagent_poll returns pending status and transcript preview" do
    parent = Conversation.create!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    from_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )
    end

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: from_node.id.to_s,
            lane_id: from_node.lane_id.to_s,
            turn_id: from_node.turn_id.to_s,
          },
          agent: { key: "main", agent_profile: "coding", context_turns: 50 },
        },
      )

    spawn = spawn_tool.call({ "name" => "child", "prompt" => "child: hello", "agent_profile" => "subagent" }, context: ctx)
    refute spawn.error?, spawn.text

    child_id = JSON.parse(spawn.text).fetch("child_conversation_id")

    poll = poll_tool.call({ "child_conversation_id" => child_id, "limit_turns" => 10 }, context: nil)
    refute poll.error?, poll.text

    payload = JSON.parse(poll.text)
    assert_equal "pending", payload.fetch("status")
    assert_includes payload.fetch("transcript_lines").join("\n"), "child: hello"
  end
end
