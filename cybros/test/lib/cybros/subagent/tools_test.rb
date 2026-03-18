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

  def send_input_tool
    @send_input_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_send_input" }
  end

  def wait_tool
    @wait_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_wait" }
  end

  def close_tool
    @close_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_close" }
  end

  test "build exposes low-level and high-level subagent tools" do
    names = Cybros::Subagent::Tools.build.map(&:name).sort

    assert_equal %w[
      subagent_approve
      subagent_close
      subagent_deny
      subagent_interrupt
      subagent_poll
      subagent_resume
      subagent_run
      subagent_send_input
      subagent_spawn
      subagent_wait
    ], names
    assert spawn_tool
    assert poll_tool
    assert run_tool
    assert wait_tool
  end

  test "subagent_run is declared parallel-safe for append queue materialization" do
    assert_equal "parallel_safe", run_tool.metadata[:execution_mode]
    assert_nil spawn_tool.metadata[:execution_mode]
  end

  test "subagent_spawn returns a runtime-owned subagent id and seeds a minimal executable turn" do
    program = create_program!
    parent =
      create_conversation!(
        agent: program,
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

    thread = find_subagent_thread!(payload.fetch("subagent_id"))
    child = find_subagent_conversation_by_subagent_id!(payload.fetch("subagent_id"))

    assert_equal payload.fetch("subagent_id"), thread.id
    assert_equal parent.id, thread.owner_conversation_id
    assert_equal graph.id, thread.owner_graph_id
    assert_equal from_node.turn_id, thread.owner_turn_id
    assert_equal from_node.id, thread.owner_node_id
    assert_equal child.id, thread.child_conversation_id
    assert_equal child.dag_graph.id, thread.child_graph_id
    assert_equal parent.agent_id, child.agent_id
    assert_nil child[:agent_program_id]
    assert_nil child[:default_execution_target_id]
    assert_equal parent.agent_config_schema_fingerprint, child.agent_config_schema_fingerprint
    assert_equal "subagent:my_agent", child.metadata.dig("agent", "key")
    assert_equal "review", child.metadata.dig("agent", "agent_profile")
    assert_equal 77, child.metadata.dig("agent", "context_turns")
    assert_equal payload.fetch("subagent_id"), child.metadata.dig("subagent", "subagent_id")
    assert_equal thread.id, child.metadata["subagent_thread_id"]
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

    other_parent = create_conversation!
    other_owner_turn = other_parent.append_user_message!(content: "Delegate this")
    other_owner_node = other_owner_turn.fetch(:agent_node)
    other_thread =
      SubagentThreads::ControlPlane.spawn!(
        parent: other_parent,
        owner_graph: other_parent.dag_graph,
        owner_turn: DAG::Turn.find(other_owner_node.turn_id),
        owner_node: other_owner_node,
        request: {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
          "context_turns" => 50,
          "title" => "Child",
          "diagnostic_level" => "standard",
        },
      )

    poll = poll_tool.call({ "subagent_id" => other_thread.id, "limit_turns" => 10 }, context: ctx)
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

  test "owner proxy tools send_input and close route through the control plane" do
    parent = create_conversation!
    ctx = parent_context(parent)

    spawn = spawn_tool.call({ "name" => "child", "prompt" => "child: hello", "agent_profile" => "subagent" }, context: ctx)
    refute spawn.error?, spawn.text
    subagent_id = JSON.parse(spawn.text).fetch("subagent_id")

    send_input = send_input_tool.call({ "subagent_id" => subagent_id, "input" => "follow up" }, context: ctx)
    refute send_input.error?, send_input.text
    assert_equal "send_input", JSON.parse(send_input.text).fetch("operation")

    close = close_tool.call({ "subagent_id" => subagent_id }, context: ctx)
    refute close.error?, close.text
    assert_equal "close", JSON.parse(close.text).fetch("operation")
  end

  test "owner proxy mutation tools reject callers from a different parent turn" do
    parent = create_conversation!
    owner_ctx = parent_context(parent)

    spawn = spawn_tool.call({ "name" => "child", "prompt" => "child: hello", "agent_profile" => "subagent" }, context: owner_ctx)
    refute spawn.error?, spawn.text
    subagent_id = JSON.parse(spawn.text).fetch("subagent_id")

    other_ctx = parent_context(parent)

    send_input = send_input_tool.call({ "subagent_id" => subagent_id, "input" => "follow up" }, context: other_ctx)
    assert send_input.error?
    assert_equal "cybros.subagent_send_input.subagent_not_owned_by_turn", send_input.metadata.dig("validation_error", "code")

    close = close_tool.call({ "subagent_id" => subagent_id }, context: other_ctx)
    assert close.error?
    assert_equal "cybros.subagent_close.subagent_not_owned_by_turn", close.metadata.dig("validation_error", "code")
  end

  test "subagent_poll ignores dangling metadata-only child conversations and returns missing" do
    parent = create_conversation!
    ctx = parent_context(parent)
    subagent_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    Conversation.create!(
      user: parent.user,
      parent_conversation: parent,
      title: "Dangling child",
      agent: parent.agent,
      agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
      metadata: {
        "agent" => {
          "key" => "subagent:dangling",
          "agent_profile" => "subagent",
          "context_turns" => 50,
        },
        "subagent" => {
          "subagent_id" => subagent_id,
          "parent_conversation_id" => parent.id.to_s,
          "parent_graph_id" => parent.dag_graph.id.to_s,
        },
      },
    )

    poll = poll_tool.call({ "subagent_id" => subagent_id, "limit_turns" => 10 }, context: ctx)
    refute poll.error?, poll.text

    payload = JSON.parse(poll.text)
    assert_equal subagent_id, payload.fetch("subagent_id")
    assert_equal "missing", payload.fetch("status")
    assert_equal [], payload.fetch("transcript_lines")
  end

  private

    def find_subagent_thread!(subagent_id)
      SubagentThread.find(subagent_id)
    end

    def find_subagent_conversation_by_subagent_id!(subagent_id)
      Conversation.where("metadata -> 'subagent' ->> 'subagent_id' = ?", subagent_id).sole
    end

    def create_program!
      create_agent_record!(
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

    def parent_context(parent, agent_key: "main", agent_profile: "coding", context_turns: 50)
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
            key: agent_key,
            agent_profile: agent_profile,
            context_turns: context_turns,
          },
        },
      )
    end
end
