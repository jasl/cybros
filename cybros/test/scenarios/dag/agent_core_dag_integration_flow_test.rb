require "test_helper"

class DAG::AgentCoreDAGIntegrationFlowTest < ActiveSupport::TestCase
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
      raise resp if resp.is_a?(Exception)

      resp
    end
  end

  class StubMCPClient
    def initialize(result_text:)
      @result_text = result_text
    end

    def list_tools(cursor: nil)
      _ = cursor

      {
        "tools" => [
          {
            "name" => "echo",
            "description" => "Echo input text",
            "inputSchema" => {
              "type" => "object",
              "additionalProperties" => false,
              "properties" => { "text" => { "type" => "string" } },
              "required" => ["text"],
            },
          },
        ],
      }
    end

    def call_tool(name:, arguments:)
      _ = name

      {
        "content" => [{ "type" => "text", "text" => "#{@result_text}:#{arguments.fetch("text")}" }],
        "isError" => false,
      }
    end
  end

  class ExplodingRegistry
    def initialize(inner:, explode_on:)
      @inner = inner
      @explode_on = explode_on.to_s
    end

    def definitions(...) = @inner.definitions(...)
    def include?(...) = @inner.include?(...)
    def find(...) = @inner.find(...)

    def execute(name:, arguments:, context: nil, tool_error_mode: :safe)
      _ = arguments
      _ = context
      _ = tool_error_mode

      if name.to_s == @explode_on
        raise StandardError, "boom"
      end

      @inner.execute(name: name, arguments: arguments, context: context, tool_error_mode: tool_error_mode)
    end
  end

  class RoleAwareTokenCounter < AgentCore::Resources::TokenCounter::Base
    def count_text(text)
      text.to_s.length
    end

    def count_messages(messages, per_message_overhead: 0)
      _ = per_message_overhead

      Array(messages).sum do |message|
        next 0 if message.respond_to?(:system?) && message.system?

        message.respond_to?(:text) ? message.text.to_s.length : 0
      end
    end

    def count_tools(tools)
      _ = tools
      0
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "LLM basic turn: user_message -> agent_message finished with content" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d100"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
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
            message: AgentCore::Message.new(role: :assistant, content: "Hi!"),
            stop_reason: :end_turn,
          ),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "Hi!", agent.body_output.fetch("content")
      assert_equal "test-model", agent.body_output.fetch("model")
      assert_equal "stub_provider", agent.body_output.fetch("provider")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "retryable provider failure before output retries and completes the same turn" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d100a"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
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
          AgentCore::ProviderError.new("rate limited", status: 429),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Recovered."),
            stop_reason: :end_turn,
          ),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "Recovered.", agent.body_output.fetch("content")
      assert_equal 2, provider.calls.length

      recovery = agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 1, recovery.fetch("recovered")
      assert_equal 0, recovery.fetch("failed")
      assert_equal false, recovery.fetch("exhausted")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "retryable provider failure exhausts recovery attempts and leaves the node errored" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d100b"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
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
          AgentCore::ProviderError.new("rate limited", status: 429),
          AgentCore::ProviderError.new("still rate limited", status: 429),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 2, provider.calls.length

      recovery = agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 0, recovery.fetch("recovered")
      assert_equal 1, recovery.fetch("failed")
      assert_equal true, recovery.fetch("exhausted")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "mixed retryable then non-retryable failures do not mark recovery as exhausted" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d100bb"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
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
          AgentCore::ProviderError.new("rate limited", status: 429),
          AgentCore::ProviderError.new("bad request", status: 400),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 2, provider.calls.length

      recovery = agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 0, recovery.fetch("recovered")
      assert_equal 1, recovery.fetch("failed")
      assert_equal false, recovery.fetch("exhausted")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "non-retryable validation error does not retry the primary call" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d100c"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
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
          AgentCore::ValidationError.new(
            "Selected model does not support tool calling",
            code: "cybros.llm.capabilities.tools_not_supported",
            details: {},
          ),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 1, provider.calls.length
      assert_nil agent.metadata.dig("llm_call", "recovery")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool_calls expansion: agent_message creates tasks and next agent_message continues" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d101"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Calling tools",
                tool_calls: [
                  AgentCore::ToolCall.new(id: "tc_1", name: "echo", arguments: { "text" => "hi" }),
                  AgentCore::ToolCall.new(id: "tc_2", name: "math.add", arguments: { "a" => 1, "b" => 2 }),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "All done."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |args, **|
        AgentCore::Resources::Tools::ToolResult.success(text: "echo=#{args.fetch("text")}")
      end
    )
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "math_add",
        description: "Add numbers",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "a" => { "type" => "number" }, "b" => { "type" => "number" } },
          required: ["a", "b"],
        },
      ) do |args, **|
        a = args.fetch("a").to_i
        b = args.fetch("b").to_i
        AgentCore::Resources::Tools::ToolResult.success(text: (a + b).to_s)
      end
    )

      runtime =
        AgentCore::DAG::Runtime.new(
          provider: provider,
          model: "test-model",
          tool_name_aliases: { "math.add" => "math_add" },
          tools_registry: tools_registry,
          tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          llm_options: { stream: false },
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
        assert_equal [agent.id], claimed.map(&:id)
        run_node_and_materialize!(graph: graph, node_id: agent.id)

        agent.reload
        resolutions = agent.metadata.dig("tool_loop", "tool_name_resolution")
        assert_equal 1, Array(resolutions).length
        assert_equal(
          {
            "tool_call_id" => "tc_2",
            "requested_name" => "math.add",
            "resolved_name" => "math_add",
            "method" => "alias",
          },
          Array(resolutions).first
        )

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 1, tasks.length
      assert_equal "echo", tasks.first.body_input.fetch("name")
      assert_equal "original", tasks.first.body_input.fetch("arguments_resolution")
      assert_nil tasks.first.body_input["repair"]

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      edge_types = graph.edges.active.where(to_node_id: next_agent.id).pluck(:edge_type).sort
      assert_equal [DAG::Edge::SEQUENCE], edge_types

      drain_serial_task_queue!(graph: graph, task_count: 2, claimed_by: "test")

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 2, tasks.length
      assert_equal ["echo", "math_add"], tasks.map { |task| task.body_input.fetch("name") }.sort
      tasks.each do |task|
        assert_equal "original", task.body_input.fetch("arguments_resolution")
        assert_nil task.body_input["repair"]
      end

      edge_types = graph.edges.active.where(to_node_id: next_agent.id).pluck(:edge_type).sort
      assert_equal [DAG::Edge::SEQUENCE, DAG::Edge::SEQUENCE], edge_types

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "All done.", next_agent.body_output.fetch("content")

      tool_result_msgs =
        provider.calls.fetch(1).fetch(:messages).select do |msg|
          msg.is_a?(AgentCore::Message) && msg.tool_result?
        end
      assert_equal ["tc_1", "tc_2"], tool_result_msgs.map(&:tool_call_id).sort
      assert tool_result_msgs.any? { |msg| msg.text.include?("echo=hi") }
      assert tool_result_msgs.any? { |msg| msg.text.include?("[tool: math_add]") && msg.text.include?("3") }

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool_name_repair_loop: repairs tool_not_in_profile to visible tool and continues" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d120"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Calling tools",
                tool_calls: [
                  AgentCore::ToolCall.new(id: "tc_1", name: "math_add", arguments: { "a" => 1, "b" => 2 }),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"name\":\"math_add_safe\"}]}"),
            stop_reason: :end_turn,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "All done."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "math_add",
        description: "Add numbers (unsafe)",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "a" => { "type" => "number" }, "b" => { "type" => "number" } },
          required: ["a", "b"],
        },
      ) do |args, **|
        a = args.fetch("a").to_i
        b = args.fetch("b").to_i
        AgentCore::Resources::Tools::ToolResult.success(text: (a + b).to_s)
      end
    )
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "math_add_safe",
        description: "Add numbers (safe)",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "a" => { "type" => "number" }, "b" => { "type" => "number" } },
          required: ["a", "b"],
        },
      ) do |args, **|
        a = args.fetch("a").to_i
        b = args.fetch("b").to_i
        AgentCore::Resources::Tools::ToolResult.success(text: (a + b).to_s)
      end
    )

    tool_policy =
      AgentCore::Resources::Tools::Policy::Profiled.new(
        allowed: ["math_add_safe"],
        delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: tool_policy,
        tool_name_repair_attempts: 1,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      name_repair = agent.metadata.dig("tool_loop", "tool_name_repair")
      assert_equal 1, name_repair.fetch("repaired")

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 1, tasks.length
      task = tasks.sole

      assert_equal "math_add", task.body_input.fetch("requested_name")
      assert_equal "math_add_safe", task.body_input.fetch("name")
      assert_equal "repaired", task.body_input.fetch("name_resolution")
      assert_equal "original", task.body_input.fetch("arguments_resolution")
      assert_equal({ "tool_name" => true }, task.body_input.fetch("repair"))

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)
      DAG::Runner.run_node!(task.id)

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "All done.", next_agent.body_output.fetch("content")

      assert_equal 3, provider.calls.length

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "max_tool_calls_per_turn: truncates tool_calls to avoid task explosion" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d119"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    tool_calls =
      (1..10).map do |i|
        AgentCore::ToolCall.new(id: "tc_#{i}", name: "echo", arguments: { "text" => i.to_s })
      end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Calling tools", tool_calls: tool_calls),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |args, **|
        AgentCore::Resources::Tools::ToolResult.success(text: args.fetch("text").to_s)
      end
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        max_tool_calls_per_turn: 3,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state

      tool_loop = agent.metadata.fetch("tool_loop")
      assert_equal 10, tool_loop.fetch("tool_calls_total")
      assert_equal 3, tool_loop.fetch("tool_calls_executed")
      assert_equal 7, tool_loop.fetch("tool_calls_omitted")

      stored_message = agent.body_output.fetch("message")
      assert_equal 3, stored_message.fetch("tool_calls").length

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 1, tasks.length

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      drain_serial_task_queue!(graph: graph, task_count: 3, claimed_by: "test")

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 3, tasks.length

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      tool_result_msgs =
        provider.calls.fetch(1).fetch(:messages).select do |msg|
          msg.is_a?(AgentCore::Message) && msg.tool_result?
        end
      assert_equal 3, tool_result_msgs.length

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool loop stores both name and args repair attribution on the final task row" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d121"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [
                  AgentCore::ToolCall.new(
                    id: "tc_1",
                    name: "echo_unsafe",
                    arguments: {},
                    arguments_parse_error: :invalid_json,
                    arguments_raw: "{\"text\":",
                  ),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"name\":\"echo_safe\"}]}"),
            stop_reason: :end_turn,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"arguments\":{\"text\":\"hi\"}}]}"),
            stop_reason: :end_turn,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    %w[echo_unsafe echo_safe].each do |tool_name|
      tools_registry.register(
        AgentCore::Resources::Tools::Tool.new(
          name: tool_name,
          description: "Echo",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: { "text" => { "type" => "string" } },
            required: ["text"],
          },
        ) do |args, **|
          AgentCore::Resources::Tools::ToolResult.success(text: "echo=#{args.fetch("text")}")
        end
      )
    end

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy:
          AgentCore::Resources::Tools::Policy::Profiled.new(
            allowed: ["echo_safe"],
            delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
          ),
        tool_name_repair_attempts: 1,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal "echo_unsafe", task.body_input.fetch("requested_name")
      assert_equal "echo_safe", task.body_input.fetch("name")
      assert_equal "repaired", task.body_input.fetch("name_resolution")
      assert_equal "repaired", task.body_input.fetch("arguments_resolution")
      assert_equal({ "tool_name" => true, "arguments" => true }, task.body_input.fetch("repair"))
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "optional approval: deny unblocks next agent_message via sequence edge" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d102"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do it", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Need approval",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: "danger", arguments: {})],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Continued."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "danger",
        description: "Dangerous",
        parameters: { type: "object", additionalProperties: false },
      ) { |_args, **| AgentCore::Resources::Tools::ToolResult.success(text: "ok") }
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::ConfirmAll.new(required: false, deny_effect: nil),
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal DAG::Node::AWAITING_APPROVAL, task.state

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      blocking_edge = graph.edges.active.where(from_node_id: task.id, to_node_id: next_agent.id).sole
      assert_equal DAG::Edge::SEQUENCE, blocking_edge.edge_type

      assert_equal [], DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")

      task.deny_approval!(reason: "approval_denied")

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "Continued.", next_agent.body_output.fetch("content")

      tool_result_msgs =
        provider.calls.fetch(1).fetch(:messages).select do |msg|
          msg.is_a?(AgentCore::Message) && msg.tool_result?
        end
      assert_equal ["tc_1"], tool_result_msgs.map(&:tool_call_id)
      assert_includes tool_result_msgs.first.text, "denied"

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "required approval: deny blocks next agent_message via dependency edge; retry->approve continues" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d103"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do it", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Need approval",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: "danger", arguments: {})],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Done after approval."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "danger",
        description: "Dangerous",
        parameters: { type: "object", additionalProperties: false },
      ) { |_args, **| AgentCore::Resources::Tools::ToolResult.success(text: "ok") }
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::ConfirmAll.new(required: true, deny_effect: "block"),
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal DAG::Node::AWAITING_APPROVAL, task.state

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      blocking_edge = graph.edges.active.where(from_node_id: task.id, to_node_id: next_agent.id).sole
      assert_equal DAG::Edge::DEPENDENCY, blocking_edge.edge_type

      task.deny_approval!(reason: "approval_denied")

      DAG::FailurePropagation.propagate!(graph: graph)
      next_agent.reload
      assert_equal DAG::Node::PENDING, next_agent.state

      assert_equal [], DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")

      retried_task = task.retry!
      assert_equal DAG::Node::AWAITING_APPROVAL, retried_task.state

      assert retried_task.approve!

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [retried_task.id], claimed.map(&:id)
      DAG::Runner.run_node!(retried_task.id)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "Done after approval.", next_agent.body_output.fetch("content")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool failure: task errored still allows next agent_message via sequence edge" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d104"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do it", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: "explode", arguments: {})],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Recovered."),
            stop_reason: :end_turn,
          ),
        ]
      )

    inner_registry = AgentCore::Resources::Tools::Registry.new
    inner_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "explode",
        description: "Explode",
        parameters: { type: "object", additionalProperties: false },
      ) { |_args, **| AgentCore::Resources::Tools::ToolResult.success(text: "nope") }
    )

    exploding_registry = ExplodingRegistry.new(inner: inner_registry, explode_on: "explode")

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: exploding_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)
      DAG::Runner.run_node!(task.id)

      task.reload
      assert_equal DAG::Node::ERRORED, task.state
      assert_includes task.metadata.fetch("error"), "boom"

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "Recovered.", next_agent.body_output.fetch("content")

      tool_result_msgs =
        provider.calls.fetch(1).fetch(:messages).select do |msg|
          msg.is_a?(AgentCore::Message) && msg.tool_result?
        end
      assert_equal ["tc_1"], tool_result_msgs.map(&:tool_call_id)
      assert_includes tool_result_msgs.first.text, "errored"

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "MCP tool: registry.register_mcp_client + task execution result injected into next LLM call" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d105"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Use MCP", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    tools_registry = AgentCore::Resources::Tools::Registry.new
    client = StubMCPClient.new(result_text: "mcp")
    tools_registry.register_mcp_client(client, server_id: "test")
    mcp_tool_name = AgentCore::MCP::ToolAdapter.local_tool_name(server_id: "test", remote_tool_name: "echo")

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call MCP",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: mcp_tool_name, arguments: { "text" => "hi" })],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal "mcp", task.metadata.fetch("source")

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)
      DAG::Runner.run_node!(task.id)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      tool_result_msgs =
        provider.calls.fetch(1).fetch(:messages).select do |msg|
          msg.is_a?(AgentCore::Message) && msg.tool_result?
        end
      assert_equal ["tc_1"], tool_result_msgs.map(&:tool_call_id)
      assert tool_result_msgs.first.text.include?("mcp:hi")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "skills tools: available_skills injected; read_file enforces rel_path validation" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d106"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Use skills", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    skills_dir = Rails.root.join("test/lib/fixtures/skills")
    store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: [skills_dir.to_s])

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register_skills_store(store)

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Read file",
                  tool_calls: [
                    AgentCore::ToolCall.new(
                      id: "tc_1",
                      name: "skills_read_file",
                      arguments: { "name" => "another-skill", "rel_path" => "references/guide.md" },
                    ),
                    AgentCore::ToolCall.new(
                      id: "tc_2",
                      name: "skills_read_file",
                      arguments: { "name" => "another-skill", "rel_path" => "../secrets.txt" },
                    ),
                  ],
                ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        skills_store: store,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      system_prompt = provider.calls.fetch(0).fetch(:messages).first.text
      assert_includes system_prompt, "<available_skills>"

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 1, tasks.length

      drain_serial_task_queue!(graph: graph, task_count: 2, claimed_by: "test")

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 2, tasks.length

      good = tasks.first.reload.body_output.dig("result")
      bad = tasks.last.reload.body_output.dig("result")

      assert_equal false, good.fetch("error")
      assert_equal true, bad.fetch("error")
      assert_includes bad.fetch("content").first.fetch("text"), "Invalid skill file path"

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "memory injection: memory search results are included in system prompt" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d107"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "pizza", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
    )

    memory_store = AgentCore::Resources::Memory::InMemory.new
    memory_store.store(content: "User preference: likes pizza", metadata: {})
    memory_store.store(content: "User preference: hates pizza", metadata: {})

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        memory_store: memory_store,
        memory_search_limit: 1,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      system_prompt = provider.calls.fetch(0).fetch(:messages).first.text
      assert_includes system_prompt, "<relevant_context>"
      assert_includes system_prompt, "likes pizza"
      refute_includes system_prompt, "hates pizza"

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context budget does not keep advising compact_context after a same-fingerprint noop compaction" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    turn_id = SecureRandom.uuid
    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Need a lot of context #{"x" * 50}",
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
                content: "Compacting context",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_compact", name: "compact_context", arguments: { "reason" => "soft_limit_reached" })],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Done."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register_many(Cybros::ContextBudget::Tools.build)

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy:
          AgentCore::Resources::Tools::Policy::Profiled.new(
            allowed: ["*"],
            hidden: ["compact_context"],
            context_allowed: lambda { |context|
              if context&.attributes&.dig(:context_budget, :budget_action).to_s == "advise_compact"
                ["compact_context"]
              else
                []
              end
            },
            delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
          ),
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 100,
        context_soft_limit_tokens: 40,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        token_counter: RoleAwareTokenCounter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      compact_task = graph.nodes.active.where(node_type: Messages::Task.node_type_key, turn_id: agent.turn_id).sole
      assert_equal "compact_context", compact_task.body_input["name"]

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test-task")
      assert_equal [compact_task.id], claimed.map(&:id)
      DAG::Runner.run_node!(compact_task.id)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test-next")
      assert_equal 1, claimed.length
      next_agent = claimed.sole
      assert_equal Messages::AgentMessage.node_type_key, next_agent.node_type
      DAG::Runner.run_node!(next_agent.id)
      next_agent.reload
      assert_equal 2, provider.calls.length, -> {
        {
          next_agent: next_agent.attributes.slice("id", "node_type", "state", "metadata", "body_output"),
          active_nodes: graph.nodes.active.order(:created_at).map { |n| n.attributes.slice("id", "node_type", "state", "metadata", "body_input", "body_output") },
        }.inspect
      }

      first_tool_names = Array(provider.calls.fetch(0).fetch(:tools)).map { |tool| tool.dig(:function, :name) || tool.dig("function", "name") || tool[:name] || tool["name"] }
      second_tool_names = Array(provider.calls.fetch(1).fetch(:tools)).map { |tool| tool.dig(:function, :name) || tool.dig("function", "name") || tool[:name] || tool["name"] }

      assert_includes first_tool_names, "compact_context"
      refute_includes second_tool_names, "compact_context"
      assert_equal "none", next_agent.metadata.dig("context_budget", "budget_action")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context budget guidance exposes compact_context only after visibility masking when bundled policy advises compaction" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d113a"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Need a lot of context #{"x" * 200}",
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
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |args, **|
        AgentCore::Resources::Tools::ToolResult.success(text: args.fetch("text"))
      end
    )
    tools_registry.register_many(Cybros::ContextBudget::Tools.build)

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy:
          AgentCore::Resources::Tools::Policy::Profiled.new(
            allowed: ["*"],
            hidden: ["compact_context"],
            context_allowed: lambda { |context|
              if context&.attributes&.dig(:context_budget, :budget_action).to_s == "advise_compact"
                ["compact_context"]
              else
                []
              end
            },
            delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
          ),
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 5000,
        context_soft_limit_tokens: 1,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        token_counter: AgentCore::Resources::TokenCounter::HeuristicWithOverhead.new(
          chars_per_token: 1.0,
          non_ascii_chars_per_token: 1.0,
          per_message_overhead: 0,
        ),
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      first_call = provider.calls.fetch(0)
      tool_names = Array(first_call.fetch(:tools)).map { |tool| tool.dig(:function, :name) || tool.dig("function", "name") || tool[:name] || tool["name"] }
      assert_includes tool_names, "compact_context"

      system_prompt = first_call.fetch(:messages).first.text
      assert_includes system_prompt, "\"budget_state\":\"soft_limit_reached\""
      assert_includes system_prompt, "\"compact_context_available\":true"
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context budget soft limit lets the model call compact_context as a normal task" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    prior_turn_id = "0194f3c0-0000-7000-8000-00000000d113a"
    turn_id = "0194f3c0-0000-7000-8000-00000000d113b"

    prior_agent = nil
    agent = nil

    graph.mutate!(turn_id: prior_turn_id) do |m|
      prior_user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "Earlier context #{"x" * 6}",
          metadata: {},
        )
      prior_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          body_output: { "content" => "Earlier reply #{"y" * 4}" },
          metadata: {},
        )
      m.create_edge(from_node: prior_user, to_node: prior_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "Need a lot of context #{"x" * 18}",
          metadata: {},
        )
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )
      m.create_edge(from_node: prior_agent, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Compacting context",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_compact", name: "compact_context", arguments: { "reason" => "soft_limit_reached" })],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Compaction applied."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register_many(Cybros::ContextBudget::Tools.build)

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy:
          AgentCore::Resources::Tools::Policy::Profiled.new(
            allowed: ["*"],
            hidden: ["compact_context"],
            context_allowed: lambda { |context|
              if context&.attributes&.dig(:context_budget, :budget_action).to_s == "advise_compact"
                ["compact_context"]
              else
                []
              end
            },
            delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
          ),
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 100,
        context_soft_limit_tokens: 40,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        token_counter: RoleAwareTokenCounter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal "soft_limit_reached", agent.metadata.dig("context_budget", "budget_state")
      assert_equal "advise_compact", agent.metadata.dig("context_budget", "budget_action")

      first_call = provider.calls.fetch(0)
      tool_names = Array(first_call.fetch(:tools)).map { |tool| tool.dig(:function, :name) || tool.dig("function", "name") || tool[:name] || tool["name"] }
      assert_includes tool_names, "compact_context"

      compact_task = graph.nodes.active.where(node_type: Messages::Task.node_type_key, turn_id: agent.turn_id).sole
      assert_equal DAG::Node::PENDING, compact_task.state
      assert_equal "compact_context", compact_task.body_input["name"]
      assert_equal "model_choice", compact_task.body_input["source"]
      assert_equal agent.metadata.dig("context_budget", "budget_fingerprint"), compact_task.metadata.dig("context_budget", "budget_fingerprint")

      next_agent =
        graph.nodes.active
          .where(node_type: Messages::AgentMessage.node_type_key, turn_id: agent.turn_id, state: DAG::Node::PENDING)
          .where.not(id: agent.id)
          .sole
      assert next_agent.present?

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [compact_task.id], claimed.map(&:id)
      DAG::Runner.run_node!(compact_task.id)

      compact_task.reload
      assert_equal DAG::Node::FINISHED, compact_task.state

      summary_entry = conversation.chat_lane.lane_prompt_buffer_entries.where(buffer_name: "summaries").sole
      assert_includes summary_entry.content, "[Compacted prior context]"

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      second_call = provider.calls.fetch(1)
      assert_includes second_call.fetch(:messages).first.text, summary_entry.content

      compact_result_message = second_call.fetch(:messages).find { |message| message.role == :tool_result && message.tool_call_id == "tc_compact" }
      refute_nil compact_result_message
      assert_equal "Context compacted into lane prompt buffer.", compact_result_message.text
      refute_includes compact_result_message.text, "[Compacted prior context]"
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context budget near hard cap enqueues compact_context inside the current tool loop" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d113c"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Need room #{"x" * 90}",
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
                content: "Calling echo",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_echo", name: "echo", arguments: { "text" => "hi" })],
              ),
            stop_reason: :tool_use,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |args, **|
        AgentCore::Resources::Tools::ToolResult.success(text: args.fetch("text"))
      end
    )
    tools_registry.register_many(Cybros::ContextBudget::Tools.build)

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy:
          AgentCore::Resources::Tools::Policy::Profiled.new(
            allowed: ["*"],
            hidden: ["compact_context"],
            context_allowed: lambda { |context|
              if context&.attributes&.dig(:context_budget, :budget_action).to_s == "advise_compact"
                ["compact_context"]
              else
                []
              end
            },
            delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
          ),
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 100,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        token_counter: RoleAwareTokenCounter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal "near_hard_cap", agent.metadata.dig("context_budget", "budget_state")
      assert_equal "enqueue_compact", agent.metadata.dig("context_budget", "budget_action")

      first_call = provider.calls.fetch(0)
      tool_names = Array(first_call.fetch(:tools)).map { |tool| tool.dig(:function, :name) || tool.dig("function", "name") || tool[:name] || tool["name"] }
      refute_includes tool_names, "compact_context"

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key, turn_id: agent.turn_id).order(:created_at, :id).to_a
      assert_equal ["compact_context", "echo"], tasks.map { |task| task.body_input["name"] }

      compact_task = tasks.first
      assert_equal DAG::Node::PENDING, compact_task.state
      assert_equal "context_budget_policy", compact_task.body_input["source"]
      assert_equal "near_hard_cap", compact_task.body_input.dig("arguments", "reason")
      assert compact_task.metadata.dig("context_budget", "budget_fingerprint").present?
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context budget forced fit enqueues compact_context after trimming history to fit" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    first_turn_id = "0194f3c0-0000-7000-8000-00000000d113d"
    second_turn_id = "0194f3c0-0000-7000-8000-00000000d113e"

    first_agent = nil
    user = nil
    agent = nil

    graph.mutate!(turn_id: first_turn_id) do |m|
      history_user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "History #{"x" * 40}",
          metadata: {},
        )
      first_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
          body_output: { "content" => "Earlier reply #{"y" * 40}" },
        )
      m.create_edge(from_node: history_user, to_node: first_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    graph.mutate!(turn_id: second_turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Need action #{"z" * 40}",
          metadata: {},
        )
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )
      m.create_edge(from_node: first_agent, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Calling echo",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_echo", name: "echo", arguments: { "text" => "fit" })],
              ),
            stop_reason: :tool_use,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |args, **|
        AgentCore::Resources::Tools::ToolResult.success(text: args.fetch("text"))
      end
    )
    tools_registry.register_many(Cybros::ContextBudget::Tools.build)

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy:
          AgentCore::Resources::Tools::Policy::Profiled.new(
            allowed: ["*"],
            hidden: ["compact_context"],
            context_allowed: lambda { |context|
              if context&.attributes&.dig(:context_budget, :budget_action).to_s == "advise_compact"
                ["compact_context"]
              else
                []
              end
            },
            delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
          ),
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 100,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        token_counter: RoleAwareTokenCounter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal "forced_fit", agent.metadata.dig("context_budget", "budget_state")
      assert_equal "enqueue_compact", agent.metadata.dig("context_budget", "budget_action")

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key, turn_id: agent.turn_id).order(:created_at, :id).to_a
      assert_equal ["compact_context", "echo"], tasks.map { |task| task.body_input["name"] }

      compact_task = tasks.first
      assert_equal "forced_fit", compact_task.body_input.dig("arguments", "reason")
      assert_equal "context_budget_policy", compact_task.body_input["source"]
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context budget enqueue_compact still expands the tool loop when the model returns plain text without tool calls" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    first_turn_id = "0194f3c0-0000-7000-8000-00000000d113f"
    second_turn_id = "0194f3c0-0000-7000-8000-00000000d1140"

    first_agent = nil
    agent = nil

    graph.mutate!(turn_id: first_turn_id) do |m|
      history_user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "History #{"x" * 40}",
          metadata: {},
        )
      first_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
          body_output: { "content" => "Earlier reply #{"y" * 40}" },
        )
      m.create_edge(from_node: history_user, to_node: first_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    graph.mutate!(turn_id: second_turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Need action #{"z" * 40}",
          metadata: {},
        )
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )
      m.create_edge(from_node: first_agent, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "COMPACTION_DONE"),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register_many(Cybros::ContextBudget::Tools.build)

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 100,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        token_counter: RoleAwareTokenCounter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key, turn_id: agent.turn_id).order(:created_at, :id).to_a
      assert_equal ["compact_context"], tasks.map { |task| task.body_input["name"] }
      assert_equal "context_budget_policy", tasks.first.body_input["source"]

      next_agent =
        graph.nodes.active
          .where(turn_id: agent.turn_id, node_type: Messages::AgentMessage.node_type_key)
          .where.not(id: agent.id)
          .order(:created_at, :id)
          .last
      assert next_agent.present?, "expected a follow-up agent node after auto-enqueued compaction"
      assert_equal DAG::Node::PENDING, next_agent.state
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: MessageComplete without TextDelta still persists final content" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d114"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::MessageComplete.new(
          message: AgentCore::Message.new(role: :assistant, content: "Hi!")
        )
        y << AgentCore::StreamEvent::Done.new(stop_reason: :end_turn)
      end

    provider = StubProvider.new(responses: [enum])

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: true },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "Hi!", agent.body_output.fetch("content")

      deltas = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_DELTA])
      assert_equal [], deltas

      compacted = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_COMPACTED])
      assert_equal [], compacted

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: TextDelta output is materialized and deltas are compacted" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d115"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::TextDelta.new(text: "Hel")
        y << AgentCore::StreamEvent::TextDelta.new(text: "lo")
        y << AgentCore::StreamEvent::MessageComplete.new(
          message: AgentCore::Message.new(role: :assistant, content: "Hello")
        )
        y << AgentCore::StreamEvent::Done.new(stop_reason: :end_turn)
      end

    provider = StubProvider.new(responses: [enum])

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: true },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "Hello", agent.body_output.fetch("content")

      deltas = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_DELTA])
      assert_equal [], deltas

      compacted = graph.node_event_page_for(agent.id, kinds: [DAG::NodeEvent::OUTPUT_COMPACTED])
      assert_equal 1, compacted.length

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "invalid tool arguments: creates finished task and continues to next agent_message" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d116"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [
                  AgentCore::ToolCall.new(
                    id: "tc_1",
                    name: "echo",
                    arguments: {},
                    arguments_parse_error: :invalid_json,
                  ),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: { type: "object", additionalProperties: false },
      ) { |_args, **| AgentCore::Resources::Tools::ToolResult.success(text: "ok") }
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal DAG::Node::FINISHED, task.state
      assert_equal "invalid_args", task.metadata.fetch("source")
      assert_equal true, task.body_output.dig("result", "error")

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      tool_result_msgs =
        provider.calls.fetch(1).fetch(:messages).select do |msg|
          msg.is_a?(AgentCore::Message) && msg.tool_result?
        end
      assert_equal ["tc_1"], tool_result_msgs.map(&:tool_call_id)
      assert_includes tool_result_msgs.first.text, "Invalid tool arguments"

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: retryable stream bootstrap failure retries before any output is committed" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d115a"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    first_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::ErrorEvent.new(error: StandardError.new("stream bootstrap failed"), recoverable: true)
      end

    second_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::MessageComplete.new(
          message: AgentCore::Message.new(role: :assistant, content: "Recovered stream.")
        )
        y << AgentCore::StreamEvent::Done.new(stop_reason: :end_turn)
      end

    provider = StubProvider.new(responses: [first_enum, second_enum])

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: true },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "Recovered stream.", agent.body_output.fetch("content")
      assert_equal 2, provider.calls.length

      recovery = agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 1, recovery.fetch("recovered")
      assert_equal false, recovery.fetch("exhausted")

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: generic non-recoverable bootstrap failure before output does not retry" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d115ac"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    first_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::ErrorEvent.new(error: StandardError.new("stream bug"), recoverable: false)
      end

    second_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::MessageComplete.new(
          message: AgentCore::Message.new(role: :assistant, content: "Should not retry")
        )
        y << AgentCore::StreamEvent::Done.new(stop_reason: :end_turn)
      end

    provider = StubProvider.new(responses: [first_enum, second_enum])

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: true },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 1, provider.calls.length

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: non-retryable provider error before output does not retry" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d115aa"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    first_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::ErrorEvent.new(error: AgentCore::ProviderError.new("bad request", status: 400))
      end

    second_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::MessageComplete.new(
          message: AgentCore::Message.new(role: :assistant, content: "Should not retry")
        )
        y << AgentCore::StreamEvent::Done.new(stop_reason: :end_turn)
      end

    provider = StubProvider.new(responses: [first_enum, second_enum])

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: true },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 1, provider.calls.length

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: validation error subclasses before output do not retry" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d115ab"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    first_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::ErrorEvent.new(
          error: AgentCore::ConfigurationError.new("bad config", code: "agent_core.bad_config", details: {})
        )
      end

    second_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::MessageComplete.new(
          message: AgentCore::Message.new(role: :assistant, content: "Should not retry")
        )
        y << AgentCore::StreamEvent::Done.new(stop_reason: :end_turn)
      end

    provider = StubProvider.new(responses: [first_enum, second_enum])

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: true },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 1, provider.calls.length

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: failure after visible output does not retry automatically" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d115b"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    first_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::TextDelta.new(text: "Hel")
        y << AgentCore::StreamEvent::ErrorEvent.new(error: StandardError.new("stream interrupted"))
      end

    second_enum =
      Enumerator.new do |y|
        y << AgentCore::StreamEvent::MessageComplete.new(
          message: AgentCore::Message.new(role: :assistant, content: "Should not retry")
        )
        y << AgentCore::StreamEvent::Done.new(stop_reason: :end_turn)
      end

    provider = StubProvider.new(responses: [first_enum, second_enum])

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: true },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 1, provider.calls.length
      assert_match(/stream interrupted/, agent.metadata.fetch("error"))

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool_call_repair_loop: repairs invalid_json tool arguments and executes tool" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d120"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [
                  AgentCore::ToolCall.new(
                    id: "tc_1",
                    name: "echo",
                    arguments: {},
                    arguments_parse_error: :invalid_json,
                    arguments_raw: "{\"text\":",
                  ),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"arguments\":{\"text\":\"hi\"}}]}",
              ),
            stop_reason: :end_turn,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |args, **|
        AgentCore::Resources::Tools::ToolResult.success(text: "echo=#{args.fetch("text")}")
      end
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      repair = agent.metadata.dig("tool_loop", "repair")
      assert_equal 1, repair.fetch("repaired")

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal({ "text" => "hi" }, task.body_input.fetch("arguments"))
      assert_equal "repaired", task.body_input.fetch("arguments_resolution")
      assert_equal({ "arguments" => true }, task.body_input.fetch("repair"))

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)
      DAG::Runner.run_node!(task.id)

      next_agent =
        graph.nodes.active
          .where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
          .where.not(id: agent.id)
          .sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      assert_equal 3, provider.calls.length
      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool_call_repair_loop: repairs schema_invalid tool arguments and executes tool" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d122"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [
                  AgentCore::ToolCall.new(
                    id: "tc_1",
                    name: "echo",
                    arguments: {},
                  ),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"arguments\":{\"text\":\"hi\"}}]}",
              ),
            stop_reason: :end_turn,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |args, **|
        AgentCore::Resources::Tools::ToolResult.success(text: "echo=#{args.fetch("text")}")
      end
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      repair = agent.metadata.dig("tool_loop", "repair")
      assert_equal 1, repair.fetch("repaired")

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal({ "text" => "hi" }, task.body_input.fetch("arguments"))
      assert_equal "repaired", task.body_input.fetch("arguments_resolution")
      assert_equal({ "arguments" => true }, task.body_input.fetch("repair"))

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)
      DAG::Runner.run_node!(task.id)

      next_agent =
        graph.nodes.active
          .where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
          .where.not(id: agent.id)
          .sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      assert_equal 3, provider.calls.length
      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool_call_repair_loop: schema_invalid args do not execute tool when repair is disabled" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d123"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [
                  AgentCore::ToolCall.new(
                    id: "tc_1",
                    name: "echo",
                    arguments: {},
                  ),
                ],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    executed = 0

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { "type" => "string" } },
          required: ["text"],
        },
      ) do |_args, **|
        executed += 1
        AgentCore::Resources::Tools::ToolResult.success(text: "ok")
      end
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        tool_call_repair_attempts: 0,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal 0, executed
      assert_equal 1, agent.metadata.dig("tool_loop", "invalid_schema_args", "count")

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal DAG::Node::FINISHED, task.state
      assert_equal "invalid_args", task.metadata.fetch("source")
      assert_equal true, task.body_output.dig("result", "error")
      assert_equal "invalid", task.body_input.fetch("arguments_resolution")
      assert_nil task.body_input["repair"]

      next_agent =
        graph.nodes.active
          .where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
          .where.not(id: agent.id)
          .sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      assert_equal 2, provider.calls.length
      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "provider_failover: does not retry with fallback models (hard error)" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d121"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      Class.new(AgentCore::Resources::Provider::Base) do
        def initialize
          @calls = []
        end

        attr_reader :calls

        def name = "failover_provider"

        def chat(messages:, model:, tools: nil, stream: false, **options)
          @calls << { messages: messages, model: model, tools: tools, stream: stream, options: options }

          if model == "primary-model"
            raise AgentCore::ProviderError.new("tools not supported", status: 400, body: { "error" => "tools not supported" })
          end

          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Hi!"),
            stop_reason: :end_turn,
          )
        end
      end.new

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "primary-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal ["primary-model"], provider.calls.map { |c| c.fetch(:model) }
      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "tool not found: creates finished task and continues to next agent_message" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d117"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: "no_such_tool", arguments: {})],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "Ok."),
            stop_reason: :end_turn,
          ),
        ]
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      assert_equal DAG::Node::FINISHED, task.state
      assert_includes task.body_output.dig("result", "content").first.fetch("text"), "Tool not found"

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      tool_result_msgs =
        provider.calls.fetch(1).fetch(:messages).select do |msg|
          msg.is_a?(AgentCore::Message) && msg.tool_result?
        end
      assert_equal ["tc_1"], tool_result_msgs.map(&:tool_call_id)
      assert_includes tool_result_msgs.first.text, "Tool not found"

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "max_steps_per_turn: tool loop is not expanded when limit exceeded" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d118"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Call tool",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: "echo", arguments: {})],
              ),
            stop_reason: :tool_use,
          ),
        ]
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new
    tools_registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: { type: "object", additionalProperties: false },
      ) { |_args, **| AgentCore::Resources::Tools::ToolResult.success(text: "ok") }
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: tools_registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        max_steps_per_turn: 1,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      run_node_and_materialize!(graph: graph, node_id: agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "Stopped: exceeded max_steps_per_turn.", agent.body_output.fetch("content")
      assert_equal "max_steps_exceeded", agent.metadata.fetch("reason")

      assert_equal 0, graph.nodes.active.where(node_type: Messages::Task.node_type_key).count
      assert_equal 0, graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).count

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  private

    def run_node_and_materialize!(graph:, node_id:)
      DAG::Runner.run_node!(node_id)
      TurnInternalTasks::Materializer.materialize_ready!(graph: graph)
    end

    def drain_serial_task_queue!(graph:, task_count:, claimed_by:)
      task_count.times do
        claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: claimed_by)
        assert_equal 1, claimed.length
        task = claimed.sole
        assert_equal Messages::Task.node_type_key, task.node_type
        DAG::Runner.run_node!(task.id)
      end
    end
end
