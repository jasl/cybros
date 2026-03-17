require "test_helper"

class AgentCore::DAG::AgentMessageExecutorRuntimeSurfaceTest < ActiveSupport::TestCase
  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(tool_name:, arguments: {})
      @tool_name = tool_name
      @arguments = arguments
    end

    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      AgentCore::Resources::Provider::Response.new(
        message:
          AgentCore::Message.new(
            role: :assistant,
            content: "Need a tool",
            tool_calls: [
              AgentCore::ToolCall.new(
                id: "tc_1",
                name: @tool_name,
                arguments: @arguments,
              ),
            ],
          ),
        stop_reason: :tool_use,
      )
    end
  end

  class AllowSurface < AgentCore::RuntimeSurface::Base
    def review_tool_call(input:)
      _ = input
      AgentCore::RuntimeSurface::Decisions::ToolCallSuggestion.new(
        action: :allow,
        reason: "surface_allow",
        patched_tool_call: nil,
        metadata: {},
      )
    end
  end

  class DenySurface < AgentCore::RuntimeSurface::Base
    def review_tool_call(input:)
      _ = input
      AgentCore::RuntimeSurface::Decisions::ToolCallSuggestion.new(
        action: :deny,
        reason: "surface_denied",
        patched_tool_call: nil,
        metadata: {},
      )
    end
  end

  class AskHumanSurface < AgentCore::RuntimeSurface::Base
    def review_tool_call(input:)
      _ = input
      AgentCore::RuntimeSurface::Decisions::ToolCallSuggestion.new(
        action: :ask_human,
        reason: "surface_review",
        patched_tool_call: nil,
        metadata: {},
      )
    end
  end

  class RewriteSurface < AgentCore::RuntimeSurface::Base
    def initialize(name:, arguments: {})
      @name = name
      @arguments = arguments
    end

    def review_tool_call(input:)
      AgentCore::RuntimeSurface::Decisions::ToolCallSuggestion.new(
        action: :rewrite_args,
        reason: "surface_rewrite",
        patched_tool_call: {
          id: input.tool_call.fetch(:id),
          name: @name,
          arguments: @arguments,
        },
        metadata: {},
      )
    end
  end

  class ExplodingSurface < AgentCore::RuntimeSurface::Base
    def review_tool_call(input:)
      raise "boom: #{input.tool_call.fetch(:name)}"
    end
  end

  class DenyToolPolicy
    def filter(tools:, context:)
      _ = context
      tools
    end

    def authorize(name:, arguments:, context:)
      _ = name
      _ = arguments
      _ = context

      AgentCore::Resources::Tools::Policy::Decision.deny(reason: "static_denied")
    end
  end

  class EchoAllowDangerConfirmPolicy
    def filter(tools:, context:)
      _ = context
      tools
    end

    def authorize(name:, arguments:, context:)
      _ = arguments
      _ = context

      if name.to_s == "danger"
        AgentCore::Resources::Tools::Policy::Decision.confirm(reason: "danger_requires_review", required: false)
      else
        AgentCore::Resources::Tools::Policy::Decision.allow(reason: "safe")
      end
    end
  end

  test "static deny wins even when runtime surface suggests allow" do
    graph =
      run_tool_loop!(
        provider: StubProvider.new(tool_name: "danger"),
        tool_policy: DenyToolPolicy.new,
        runtime_surface: AllowSurface.new,
      )

    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
    result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))

    assert_equal DAG::Node::FINISHED, task.state
    assert_includes result.text, "denied by policy"
    assert_includes result.text, "static_denied"
  end

  test "static confirm cannot be bypassed by runtime surface allow" do
    graph =
      run_tool_loop!(
        provider: StubProvider.new(tool_name: "danger"),
        tool_policy: AgentCore::Resources::Tools::Policy::ConfirmAll.new(required: true, deny_effect: "block"),
        runtime_surface: AllowSurface.new,
      )

    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole

    assert_equal DAG::Node::AWAITING_APPROVAL, task.state
    assert_equal true, task.metadata.dig("approval", "required")
    assert_equal "block", task.metadata.dig("approval", "deny_effect")
  end

  test "runtime surface can tighten static allow to deny" do
    graph =
      run_tool_loop!(
        provider: StubProvider.new(tool_name: "danger"),
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        runtime_surface: DenySurface.new,
      )

    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
    result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))

    assert_equal DAG::Node::FINISHED, task.state
    assert_includes result.text, "surface_denied"
  end

  test "runtime surface can tighten static allow to ask_human" do
    graph =
      run_tool_loop!(
        provider: StubProvider.new(tool_name: "danger"),
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        runtime_surface: AskHumanSurface.new,
      )

    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole

    assert_equal DAG::Node::AWAITING_APPROVAL, task.state
    assert_equal "surface_review", task.metadata.dig("approval", "reason")
  end

  test "rewrite_args triggers revalidation and reauthorization" do
    graph =
      run_tool_loop!(
        provider: StubProvider.new(tool_name: "echo"),
        tool_policy: EchoAllowDangerConfirmPolicy.new,
        runtime_surface: RewriteSurface.new(name: "danger", arguments: {}),
      )

    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole

    assert_equal DAG::Node::AWAITING_APPROVAL, task.state
    assert_equal "danger", task.body_input.fetch("requested_name")
    assert_equal "danger", task.body_input.fetch("name")
    assert_equal "danger_requires_review", task.metadata.dig("approval", "reason")
  end

  test "runtime surface runner failures fall back to the static policy only" do
    graph =
      run_tool_loop!(
        provider: StubProvider.new(tool_name: "danger"),
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        runtime_surface: ExplodingSurface.new,
      )

    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole

    assert_equal DAG::Node::PENDING, task.state
    assert_equal "danger", task.body_input.fetch("requested_name")
    assert_equal "danger", task.body_input.fetch("name")
  end

  private

    def run_tool_loop!(provider:, tool_policy:, runtime_surface:)
      conversation = create_conversation!
      graph = conversation.dag_graph
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

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

      runtime =
        AgentCore::DAG::Runtime.new(
          provider: provider,
          model: "test-model",
          tools_registry: build_tools_registry,
          tool_policy: tool_policy,
          runtime_surface: runtime_surface,
          runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
          llm_options: { stream: false },
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )

      with_runtime(runtime) do
        claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
        assert_equal [agent.id], claimed.map(&:id)
        DAG::Runner.run_node!(agent.id)
        TurnInternalTasks::Materializer.materialize_ready!(graph: graph)
      end

      graph
    end

    def build_tools_registry
      AgentCore::Resources::Tools::Registry.new.tap do |registry|
        registry.register(
          AgentCore::Resources::Tools::Tool.new(
            name: "echo",
            description: "Echo",
            parameters: { type: "object", additionalProperties: false },
          ) { |_args, **| AgentCore::Resources::Tools::ToolResult.success(text: "ok") }
        )
        registry.register(
          AgentCore::Resources::Tools::Tool.new(
            name: "danger",
            description: "Danger",
            parameters: { type: "object", additionalProperties: false },
          ) { |_args, **| AgentCore::Resources::Tools::ToolResult.success(text: "ok") }
        )
      end
    end

    def with_runtime(runtime)
      original_runtime_resolver = AgentCore::DAG.runtime_resolver
      original_registry = DAG.executor_registry

      DAG.executor_registry = DAG::ExecutorRegistry.new
      DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
      DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

      yield
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
end
