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

      resp
    end
  end

  class AlwaysConfirmPolicy < AgentCore::Resources::Tools::Policy::Base
    def initialize(required:, deny_effect:)
      @required = required
      @deny_effect = deny_effect
    end

    def filter(tools:, context:)
      _ = context
      tools
    end

    def authorize(name:, arguments:, context:)
      _ = name
      _ = arguments
      _ = context

      AgentCore::Resources::Tools::Policy::Decision.confirm(
        reason: "needs_approval",
        required: @required,
        deny_effect: @deny_effect,
      )
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

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "LLM basic turn: user_message -> agent_message finished with content" do
    conversation = Conversation.create!
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

      DAG::Runner.run_node!(agent.id)

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

  test "tool_calls expansion: agent_message creates tasks and next agent_message continues" do
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 2, tasks.length

      names = tasks.map { |task| task.body_input.fetch("name") }.sort
      assert_equal ["echo", "math_add"], names

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      edge_types = graph.edges.active.where(to_node_id: next_agent.id).pluck(:edge_type).sort
      assert_equal [DAG::Edge::SEQUENCE, DAG::Edge::SEQUENCE], edge_types

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal tasks.map(&:id), claimed.map(&:id)
      tasks.each { |task| DAG::Runner.run_node!(task.id) }

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

  test "max_tool_calls_per_turn: truncates tool_calls to avoid task explosion" do
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state

      tool_loop = agent.metadata.fetch("tool_loop")
      assert_equal 10, tool_loop.fetch("tool_calls_total")
      assert_equal 3, tool_loop.fetch("tool_calls_executed")
      assert_equal 7, tool_loop.fetch("tool_calls_omitted")

      stored_message = agent.body_output.fetch("message")
      assert_equal 3, stored_message.fetch("tool_calls").length

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 3, tasks.length

      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal tasks.map(&:id), claimed.map(&:id)
      tasks.each { |task| DAG::Runner.run_node!(task.id) }

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

  test "optional approval: deny unblocks next agent_message via sequence edge" do
    conversation = Conversation.create!
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
        tool_policy: AlwaysConfirmPolicy.new(required: false, deny_effect: nil),
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
      DAG::Runner.run_node!(agent.id)

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
    conversation = Conversation.create!
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
        tool_policy: AlwaysConfirmPolicy.new(required: true, deny_effect: "block"),
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
      DAG::Runner.run_node!(agent.id)

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
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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
    conversation = Conversation.create!
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
                    name: "skills.read_file",
                    arguments: { "name" => "another-skill", "rel_path" => "references/guide.md" },
                  ),
                  AgentCore::ToolCall.new(
                    id: "tc_2",
                    name: "skills.read_file",
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
      DAG::Runner.run_node!(agent.id)

      system_prompt = provider.calls.fetch(0).fetch(:messages).first.text
      assert_includes system_prompt, "<available_skills>"

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 2, tasks.length

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal tasks.map(&:id), claimed.map(&:id)
      tasks.each { |task| DAG::Runner.run_node!(task.id) }

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
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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

  test "auto_compact: over-budget context triggers summarizer + graph.compress!" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    long = "x" * 600

    u1 = nil
    a1 = nil
    u2 = nil
    a2 = nil
    u3 = nil
    a3 = nil
    u4 = nil
    a4 = nil

    t1 = "0194f3c0-0000-7000-8000-00000000d110"
    t2 = "0194f3c0-0000-7000-8000-00000000d111"
    t3 = "0194f3c0-0000-7000-8000-00000000d112"
    t4 = "0194f3c0-0000-7000-8000-00000000d113"

    graph.mutate! do |m|
      u1 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t1, content: "u1 #{long}", metadata: {})
      a1 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t1, body_output: { "content" => "a1 #{long}" }, metadata: {})
      m.create_edge(from_node: u1, to_node: a1, edge_type: DAG::Edge::SEQUENCE)

      u2 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t2, content: "u2 #{long}", metadata: {})
      a2 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t2, body_output: { "content" => "a2 #{long}" }, metadata: {})
      m.create_edge(from_node: a1, to_node: u2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u2, to_node: a2, edge_type: DAG::Edge::SEQUENCE)

      u3 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t3, content: "u3 #{long}", metadata: {})
      a3 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t3, body_output: { "content" => "a3 #{long}" }, metadata: {})
      m.create_edge(from_node: a2, to_node: u3, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u3, to_node: a3, edge_type: DAG::Edge::SEQUENCE)

      u4 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t4, content: "u4 #{long}", metadata: {})
      a4 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, turn_id: t4, metadata: {})
      m.create_edge(from_node: a3, to_node: u4, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u4, to_node: a4, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "summary"),
            stop_reason: :end_turn,
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
        context_window_tokens: 200,
        reserved_output_tokens: 0,
        auto_compact: true,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [a4.id], claimed.map(&:id)
      DAG::Runner.run_node!(a4.id)

      summary = graph.nodes.active.where(node_type: "summary").sole
      assert_equal "auto_compact", summary.metadata.fetch("kind")
      assert_equal "agent_core", summary.metadata.fetch("generated_by")

      [u1, a1, u2, a2, u3, a3].each do |node|
        assert node.reload.compressed_at.present?
      end

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
  ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "streaming: MessageComplete without TextDelta still persists final content" do
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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

  test "tool not found: creates finished task and continues to next agent_message" do
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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
    conversation = Conversation.create!
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
      DAG::Runner.run_node!(agent.id)

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
end
