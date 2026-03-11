require "test_helper"

class Cybros::Subagent::ToolsTest < ActiveSupport::TestCase
  def spawn_tool
    @spawn_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_spawn" }
  end

  def poll_tool
    @poll_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_poll" }
  end

  def run_tool
    @run_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_run" }
  end

  def wait_tool
    @wait_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_wait" }
  end

  test "build exposes low-level and high-level subagent tools" do
    names = Cybros::Subagent::Tools.build.map(&:name).sort

    assert_equal %w[subagent_poll subagent_run subagent_spawn subagent_wait], names
    assert spawn_tool
    assert poll_tool
    assert run_tool
    assert wait_tool
  end

  test "subagent_spawn returns a runtime-owned subagent id and seeds a minimal executable turn" do
    program = create_program!
    parent =
      create_conversation!(
        agent_program: program,
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
    assert_match(/\A[0-9a-f\-]{36}\z/, payload.fetch("subagent_id"))
    refute payload.key?(["child", "conversation", "id"].join("_"))
    refute payload.key?("child_graph_id")

    child = find_subagent_conversation_by_subagent_id!(payload.fetch("subagent_id"))

    assert_equal parent.agent_program_id, child.agent_program_id
    assert_equal parent.agent_config_schema_fingerprint, child.agent_config_schema_fingerprint
    assert_equal "subagent:my_agent", child.metadata.dig("agent", "key")
    assert_equal "review", child.metadata.dig("agent", "agent_profile")
    assert_equal 77, child.metadata.dig("agent", "context_turns")
    assert_equal payload.fetch("subagent_id"), child.metadata.dig("subagent", "subagent_id")
    assert_equal parent.id.to_s, child.metadata.dig("subagent", "parent_conversation_id")
    assert_equal graph.id.to_s, child.metadata.dig("subagent", "parent_graph_id")
    assert_equal from_node.turn_id.to_s, child.metadata.dig("subagent", "parent_turn_id")
    assert_equal from_node.id.to_s, child.metadata.dig("subagent", "parent_dag_node_id")
    assert_equal from_node.id.to_s, child.metadata.dig("subagent", "spawned_from_node_id")

    child_graph = child.dag_graph
    user = child_graph.nodes.active.where(node_type: Messages::UserMessage.node_type_key).sole
    agent = child_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).sole

    assert_equal DAG::Node::PENDING, agent.state
    assert_equal user.turn_id, agent.turn_id

    assert child_graph.edges.active.where(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE).exists?
  end

  test "subagent_spawn rejects nested spawns" do
    parent = create_conversation!
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
    parent = create_conversation!
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
      assert_equal "cybros.subagent_spawn.context_turns_must_be_an_integer", result.metadata.dig("validation_error", "code")
    end
  end

  test "subagent_spawn rejects invalid agent_profile" do
    parent = create_conversation!
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
      assert_equal "cybros.subagent_spawn.invalid_agent_profile", result.metadata.dig("validation_error", "code")
    end
  end

  test "subagent_poll returns missing status when subagent does not exist" do
    parent = create_conversation!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: "0194f3c0-0000-7000-8000-00000000ffff",
          },
          agent: { key: "main", agent_profile: "coding", context_turns: 50 },
        },
      )

    result = poll_tool.call({ "subagent_id" => "0194f3c0-0000-7000-8000-00000000ffff" }, context: ctx)
    refute result.error?, result.text

    payload = JSON.parse(result.text)
    assert_equal "0194f3c0-0000-7000-8000-00000000ffff", payload.fetch("subagent_id")
    assert_equal "missing", payload.fetch("status")
    assert_equal [], payload.fetch("transcript_lines")
    refute payload.key?(["child", "conversation", "id"].join("_"))
  end

  test "subagent_poll rejects invalid limit_turns when provided" do
    parent = create_conversation!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: "0194f3c0-0000-7000-8000-00000000ffff",
          },
          agent: { key: "main", agent_profile: "coding", context_turns: 50 },
        },
      )

    result = poll_tool.call({ "subagent_id" => "0194f3c0-0000-7000-8000-00000000ffff", "limit_turns" => "abc" }, context: ctx)
    assert result.error?
    assert_includes result.text, "validation failed"
    assert_equal "cybros.subagent_poll.limit_turns_must_be_an_integer", result.metadata.dig("validation_error", "code")
  end

  test "subagent_poll rejects invalid subagent_id format" do
    parent = create_conversation!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    ctx =
      AgentCore::ExecutionContext.new(
        run_id: turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: graph.id.to_s,
            node_id: "0194f3c0-0000-7000-8000-00000000ffff",
          },
          agent: { key: "main", agent_profile: "coding", context_turns: 50 },
        },
      )

    result = poll_tool.call({ "subagent_id" => "not-a-uuid" }, context: ctx)
    assert result.error?
    assert_includes result.text, "validation failed"
    assert_equal "cybros.subagent_poll.subagent_id_must_be_a_uuid", result.metadata.dig("validation_error", "code")
  end

  test "subagent_poll rejects polling a non-owned subagent" do
    parent = create_conversation!
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

    other =
      create_conversation!(
        metadata: {
          "subagent" => {
            "subagent_id" => ActiveRecord::Base.connection.select_value("select uuidv7()"),
          },
        },
      )

    poll = poll_tool.call({ "subagent_id" => other.metadata.dig("subagent", "subagent_id"), "limit_turns" => 10 }, context: ctx)
    assert poll.error?
    assert_includes poll.text, "validation failed"
    assert_equal "cybros.subagent_poll.subagent_not_owned", poll.metadata.dig("validation_error", "code")
  end

  test "subagent_poll returns pending status and transcript preview" do
    parent = create_conversation!
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

    subagent_id = JSON.parse(spawn.text).fetch("subagent_id")

    poll = poll_tool.call({ "subagent_id" => subagent_id, "limit_turns" => 10 }, context: ctx)
    refute poll.error?, poll.text

    payload = JSON.parse(poll.text)
    assert_equal subagent_id, payload.fetch("subagent_id")
    assert_equal "pending", payload.fetch("status")
    assert_includes payload.fetch("transcript_lines").join("\n"), "child: hello"
    refute payload.key?(["child", "conversation", "id"].join("_"))
  end

  private

    def find_subagent_conversation_by_subagent_id!(subagent_id)
      Conversation.where("metadata -> 'subagent' ->> 'subagent_id' = ?", subagent_id).sole
    end

    def create_program!
      AgentProgram.create!(
        name: "Fixture Program #{SecureRandom.hex(4)}",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
      )
    end
end
