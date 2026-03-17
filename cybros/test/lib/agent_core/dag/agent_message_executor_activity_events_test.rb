require "test_helper"

class AgentCore::DAG::AgentMessageExecutorActivityEventsTest < ActiveSupport::TestCase
  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(responses:)
      @responses = Array(responses)
    end

    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      response = @responses.shift
      raise "unexpected provider.chat call (no remaining responses)" unless response

      response
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

      AgentCore::Resources::Tools::Policy::Decision.deny(reason: "policy_denied")
    end
  end

  test "invalid tool arguments emit planned and failed activity events" do
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Need a tool",
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
        ],
      )

    graph = run_tool_loop!(provider: provider, tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new)
    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
    events = activity_events_for(task)

    assert_equal DAG::Node::FINISHED, task.state
    assert_equal [DAG::NodeEvent::ACTIVITY_PLANNED, DAG::NodeEvent::ACTIVITY_FAILED], events.map { |event| event.fetch("kind") }
    assert_equal %w[planned failed], events.map { |event| event.fetch("payload").fetch("status") }
    assert_equal %w[planning planning], events.map { |event| event.fetch("payload").fetch("phase") }
    assert_equal ["task:#{task.id}", "task:#{task.id}"], events.map { |event| event.fetch("payload").fetch("activity_id") }
    assert_equal [task.id, task.id], events.map { |event| event.fetch("payload").fetch("source_node_id") }
    assert_includes events.last.fetch("payload").fetch("data").fetch("error"), "Invalid tool arguments"
  end

  test "approval-gated tool calls emit planned and waiting activity events" do
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
        ],
      )

    graph =
      run_tool_loop!(
        provider: provider,
        tool_policy: AgentCore::Resources::Tools::Policy::ConfirmAll.new(required: true, deny_effect: "block"),
      )
    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
    events = activity_events_for(task)

    assert_equal DAG::Node::AWAITING_APPROVAL, task.state
    assert_equal [DAG::NodeEvent::ACTIVITY_PLANNED, DAG::NodeEvent::ACTIVITY_WAITING], events.map { |event| event.fetch("kind") }
    assert_equal %w[planned awaiting_approval], events.map { |event| event.fetch("payload").fetch("status") }
    assert_equal ["planning", "authorization"], events.map { |event| event.fetch("payload").fetch("phase") }
    assert_equal true, events.last.fetch("payload").fetch("data").fetch("required")
    assert_equal "block", events.last.fetch("payload").fetch("data").fetch("deny_effect")
  end

  test "policy-denied tool calls emit planned and failed activity events" do
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Try the tool",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: "danger", arguments: {})],
              ),
            stop_reason: :tool_use,
          ),
        ],
      )

    graph = run_tool_loop!(provider: provider, tool_policy: DenyToolPolicy.new)
    task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
    events = activity_events_for(task)

    assert_equal DAG::Node::FINISHED, task.state
    assert_equal [DAG::NodeEvent::ACTIVITY_PLANNED, DAG::NodeEvent::ACTIVITY_FAILED], events.map { |event| event.fetch("kind") }
    assert_equal %w[planned failed], events.map { |event| event.fetch("payload").fetch("status") }
    assert_equal ["planning", "authorization"], events.map { |event| event.fetch("payload").fetch("phase") }
    assert_equal "policy_denied", events.last.fetch("payload").fetch("data").fetch("reason")
    assert_includes events.last.fetch("payload").fetch("data").fetch("error"), "denied by policy"
  end

  private

    def activity_events_for(task)
      task.graph.node_event_page_for(task.id, limit: 10, kinds: DAG::NodeEvent::ACTIVITY_EVENT_KINDS)
    end

    def run_tool_loop!(provider:, tool_policy:)
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
