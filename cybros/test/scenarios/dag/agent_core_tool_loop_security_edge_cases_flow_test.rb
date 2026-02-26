require "test_helper"

class DAG::AgentCoreToolLoopSecurityEdgeCasesFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(responses:)
      @responses = Array(responses)
      @calls = []
    end

    attr_reader :calls

    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @calls << { messages: messages, model: model, tools: tools, stream: stream, options: options }
      resp = @responses.shift
      raise "unexpected provider.chat call (no remaining responses)" unless resp

      resp
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "agent tool loop: subagent_poll denies non-owned conversation and does not leak transcript" do
    spawn_tool = Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_spawn" }

    other_parent = create_conversation!
    other_graph = other_parent.dag_graph
    other_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    other_from_node = nil

    other_graph.mutate!(turn_id: other_turn_id) do |m|
      other_from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "other parent",
          metadata: {},
        )
    end

    other_ctx =
      AgentCore::ExecutionContext.new(
        run_id: other_turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: other_graph.id.to_s,
            node_id: other_from_node.id.to_s,
            lane_id: other_from_node.lane_id.to_s,
            turn_id: other_from_node.turn_id.to_s,
          },
          agent: { key: "main", agent_profile: "coding", context_turns: 50 },
        },
      )

    secret = "TOP_SECRET: do not leak"
    spawn =
      spawn_tool.call(
        { "name" => "child", "prompt" => secret, "agent_profile" => "subagent" },
        context: other_ctx,
      )

    refute spawn.error?, spawn.text
    child_id = JSON.parse(spawn.text).fetch("child_conversation_id")

    parent = create_conversation!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )

      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Polling child",
                tool_calls: [
                  AgentCore::ToolCall.new(
                    id: "tc_1",
                    name: "subagent_poll",
                    arguments: { "child_conversation_id" => child_id, "limit_turns" => 10 },
                  ),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Done."),
            stop_reason: :end_turn,
          ),
        ],
      )

    tools_registry = Cybros::AgentRuntimeResolver.build_tools_registry

    runtime =
      lambda do |node:|
        base =
          Cybros::AgentRuntimeResolver.runtime_for(
            node: node,
            provider: provider,
            base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
            tools_registry: tools_registry,
            instrumenter: AgentCore::Observability::NullInstrumenter.new,
          )

        base.with(llm_options: { stream: false })
      end

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = runtime

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).last
      assert task, "expected a task node"

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)

      DAG::Runner.run_node!(task.id)

      task.reload
      assert_equal DAG::Node::FINISHED, task.state

      tool_result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))
      assert tool_result.error?
      assert_equal "cybros.subagent_poll.child_conversation_not_owned", tool_result.metadata.dig("validation_error", "code")
      refute_includes tool_result.text, secret

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).order(:id).last
      assert next_agent, "expected next agent node"

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(next_agent.id)

      tool_msg =
        provider.calls
          .fetch(1)
          .fetch(:messages)
          .find { |m| m.role == :tool_result && m.tool_call_id == "tc_1" }

      assert tool_msg, "expected tool_result message with tool_call_id tc_1"
      refute_includes tool_msg.text, secret

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "agent tool loop: memory_forget invalid uuid surfaces validation_error in task result" do
    parent = create_conversation!
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )

      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Forgetting memory",
                tool_calls: [
                  AgentCore::ToolCall.new(
                    id: "tc_1",
                    name: "memory_forget",
                    arguments: { "id" => "not-a-uuid" },
                  ),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Done."),
            stop_reason: :end_turn,
          ),
        ],
      )

    embedder =
      Class.new do
        def embed(text:)
          _ = text
          Array.new(1536, 0.0)
        end
      end.new

    store =
      AgentCore::Resources::Memory::PgvectorStore.new(
        embedder: embedder,
        conversation_id: nil,
        include_global: true,
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register_memory_store(store)

    runtime =
      lambda do |node:|
        base =
          Cybros::AgentRuntimeResolver.runtime_for(
            node: node,
            provider: provider,
            base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
            tools_registry: tools_registry,
            instrumenter: AgentCore::Observability::NullInstrumenter.new,
          )

        base.with(llm_options: { stream: false })
      end

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = runtime

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).last
      assert task, "expected a task node"

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)

      DAG::Runner.run_node!(task.id)

      task.reload
      assert_equal DAG::Node::FINISHED, task.state

      tool_result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))
      assert tool_result.error?
      assert_equal "agent_core.memory.pgvector_store.id_must_be_a_uuid", tool_result.metadata.dig("validation_error", "code")

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).order(:id).last
      assert next_agent, "expected next agent node"

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(next_agent.id)

      tool_msg =
        provider.calls
          .fetch(1)
          .fetch(:messages)
          .find { |m| m.role == :tool_result && m.tool_call_id == "tc_1" }

      assert tool_msg, "expected tool_result message with tool_call_id tc_1"
      assert_includes tool_msg.text, "id must be a UUID"

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end
end
