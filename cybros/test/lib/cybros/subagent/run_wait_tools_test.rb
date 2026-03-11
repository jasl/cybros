require "test_helper"

class Cybros::Subagent::RunWaitToolsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FinishingChildAgentExecutor
    def initialize(content:)
      @content = content
    end

    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream

      DAG::ExecutionResult.finished(content: @content)
    end
  end

  def run_tool
    @run_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_run" }
  end

  def wait_tool
    @wait_tool ||= Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_wait" }
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "subagent_run spawns a background subagent thread and returns its runtime-owned status snapshot" do
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

    ctx = parent_context(parent, agent_profile: "review", context_turns: 88)
    result = nil

    assert_enqueued_with(job: DAG::TickGraphJob) do
      result =
        run_tool.call(
          {
            "name" => "My Agent",
            "prompt" => "child: hello",
            "agent_profile" => "subagent",
            "diagnostic_level" => "debug",
          },
          context: ctx,
        )
    end

    refute result.error?, result.text

    payload = JSON.parse(result.text)
    child = find_subagent_conversation_by_subagent_id!(payload.fetch("subagent_id"))
    child_graph = child.dag_graph
    child_leaf = child_graph.leaf_nodes.where(lane_id: child_graph.main_lane.id).order(:id).last

    assert_equal true, payload.fetch("ok")
    assert_equal "run", payload.fetch("operation")
    assert_match(/\A[0-9a-f\-]{36}\z/, payload.fetch("subagent_id"))
    assert_equal "pending", payload.fetch("status")
    assert_equal({ "pending" => 1, "running" => 0, "awaiting_approval" => 0 }, payload.fetch("counts"))
    assert_equal "debug", payload.fetch("diagnostic_level")
    assert_equal child_leaf.id.to_s, payload.dig("leaf", "node_id")
    assert_equal DAG::Node::PENDING, payload.dig("leaf", "state")
    assert_includes payload.fetch("transcript_lines").join("\n"), "child: hello"
    refute payload.key?(["child", "conversation", "id"].join("_"))
    refute payload.key?("child_graph_id")

    assert_equal parent.agent_program_id, child.agent_program_id
    assert_equal parent.agent_config_schema_fingerprint, child.agent_config_schema_fingerprint
    assert_equal "subagent:my_agent", child.metadata.dig("agent", "key")
    assert_equal "subagent", child.metadata.dig("agent", "agent_profile")
    assert_equal 88, child.metadata.dig("agent", "context_turns")
    assert_equal payload.fetch("subagent_id"), child.metadata.dig("subagent", "subagent_id")
    assert_equal parent.id.to_s, child.metadata.dig("subagent", "parent_conversation_id")
    assert_equal ctx.attributes.dig(:dag, :turn_id).to_s, child.metadata.dig("subagent", "parent_turn_id")
    assert_equal ctx.attributes.dig(:dag, :node_id).to_s, child.metadata.dig("subagent", "parent_dag_node_id")
    assert_equal "debug", child_leaf.metadata.dig("turn_execution", "diagnostic_level")

    assert_equal child_graph.id.to_s, enqueued_jobs.last[:args].first.to_s
    assert_equal payload, result.metadata.fetch("subagent")
  end

  test "subagent_wait returns a settled bounded snapshot once the child is idle" do
    parent = create_conversation!
    ctx = parent_context(parent)

    registry = DAG::ExecutorRegistry.new
    registry.register(
      Messages::AgentMessage.node_type_key,
      FinishingChildAgentExecutor.new(content: "child: done"),
    )

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      child_id = nil

      perform_enqueued_jobs do
        run =
          run_tool.call(
            {
              "name" => "child",
              "prompt" => "child: hello",
              "agent_profile" => "subagent",
            },
            context: ctx,
          )

        refute run.error?, run.text
        child_id = JSON.parse(run.text).fetch("subagent_id")
      end

      wait =
        wait_tool.call(
          {
            "subagent_id" => child_id,
            "limit_turns" => 10,
            "timeout_ms" => 5,
          },
          context: ctx,
        )

      refute wait.error?, wait.text

      payload = JSON.parse(wait.text)
      assert_equal "wait", payload.fetch("operation")
      assert_equal "settled", payload.fetch("wait_status")
      assert_equal false, payload.fetch("timed_out")
      assert_equal 5, payload.fetch("timeout_ms")
      assert_equal "idle", payload.fetch("status")
      assert_equal({ "pending" => 0, "running" => 0, "awaiting_approval" => 0 }, payload.fetch("counts"))
      assert_equal({ "final_output" => "child: done" }, payload.fetch("result"))
      assert_equal(
        {
          "format" => "text",
          "content" => "child: done",
          "scope" => "full",
        },
        payload.fetch("assistant_output_candidate"),
      )
      assert_includes payload.fetch("transcript_lines").join("\n"), "child: hello"
      assert_includes payload.fetch("transcript_lines").join("\n"), "child: done"
      assert_operator payload.fetch("elapsed_ms"), :>=, 0
    ensure
      DAG.executor_registry = original_registry
    end
  end

  test "subagent_wait returns a timeout snapshot without changing child ownership rules" do
    parent = create_conversation!
    ctx = parent_context(parent)

    run =
      run_tool.call(
        {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
        },
        context: ctx,
      )
    refute run.error?, run.text

    child = find_subagent_conversation_by_subagent_id!(JSON.parse(run.text).fetch("subagent_id"))
    child_leaf = child.dag_graph.leaf_nodes.where(lane_id: child.dag_graph.main_lane.id).order(:id).last
    child_leaf.mark_running!

    wait =
      wait_tool.call(
        {
          "subagent_id" => child.metadata.dig("subagent", "subagent_id"),
          "timeout_ms" => 0,
          "limit_turns" => 10,
        },
        context: ctx,
      )
    refute wait.error?, wait.text

    payload = JSON.parse(wait.text)
    assert_equal "running", payload.fetch("status")
    assert_equal "timeout", payload.fetch("wait_status")
    assert_equal true, payload.fetch("timed_out")
    assert_equal({ "pending" => 0, "running" => 1, "awaiting_approval" => 0 }, payload.fetch("counts"))

    other =
      create_conversation!(
        metadata: {
          "subagent" => {
            "subagent_id" => ActiveRecord::Base.connection.select_value("select uuidv7()"),
          },
        },
      )

    rejected =
      wait_tool.call(
        {
          "subagent_id" => other.metadata.dig("subagent", "subagent_id"),
          "timeout_ms" => 0,
        },
        context: ctx,
      )

    assert rejected.error?
    assert_equal "cybros.subagent_wait.subagent_not_owned", rejected.metadata.dig("validation_error", "code")
  end

  test "subagent_run rejects nested spawn and debug mode keeps the worker boundary narrow" do
    parent = create_conversation!
    ctx = parent_context(parent, agent_key: "subagent:child", agent_profile: "subagent")

    assert_no_difference -> { Conversation.count } do
      nested =
        run_tool.call(
          {
            "name" => "nested",
            "prompt" => "hi",
          },
          context: ctx,
        )

      assert nested.error?
      assert_equal "cybros.subagent_run.nested_spawn_not_allowed", nested.metadata.dig("validation_error", "code")
    end

    standard_ctx = parent_context(parent)
    standard_run =
      run_tool.call(
        {
          "name" => "standard",
          "prompt" => "child: standard",
          "agent_profile" => "subagent",
        },
        context: standard_ctx,
      )
    debug_run =
      run_tool.call(
        {
          "name" => "debug",
          "prompt" => "child: debug",
          "agent_profile" => "subagent",
          "diagnostic_level" => "debug",
        },
        context: standard_ctx,
      )

    refute standard_run.error?, standard_run.text
    refute debug_run.error?, debug_run.text

    standard_child = find_subagent_conversation_by_subagent_id!(JSON.parse(standard_run.text).fetch("subagent_id"))
    debug_child = find_subagent_conversation_by_subagent_id!(JSON.parse(debug_run.text).fetch("subagent_id"))

    standard_agent = standard_child.dag_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).sole
    debug_agent = debug_child.dag_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).sole

    tools_registry = Cybros::AgentRuntimeResolver.build_tools_registry
    base_policy = AgentCore::Resources::Tools::Policy::AllowAll.new
    instrumenter = AgentCore::Observability::NullInstrumenter.new

    standard_runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: standard_agent,
        base_tool_policy: base_policy,
        tools_registry: tools_registry,
        instrumenter: instrumenter,
      )
    debug_runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: debug_agent,
        base_tool_policy: base_policy,
        tools_registry: tools_registry,
        instrumenter: instrumenter,
      )

    decision_context = AgentCore::ExecutionContext.new(run_id: "subagent-boundary")
    standard_decision =
      standard_runtime.tool_policy.authorize(
        name: "memory_search",
        arguments: { "query" => "hi", "limit" => 1 },
        context: decision_context,
      )
    debug_decision =
      debug_runtime.tool_policy.authorize(
        name: "memory_search",
        arguments: { "query" => "hi", "limit" => 1 },
        context: decision_context,
      )

    assert_equal "standard", standard_agent.metadata.dig("turn_execution", "diagnostic_level")
    assert_equal "debug", debug_agent.metadata.dig("turn_execution", "diagnostic_level")
    assert_equal [standard_decision.outcome, standard_decision.reason], [debug_decision.outcome, debug_decision.reason]
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
