require "test_helper"

class AgentCore::DAG::TaskExecutorActivityEventsTest < ActiveSupport::TestCase
  test "task execution emits activity_started and activity_finished events" do
    conversation = create_conversation!
    task = create_task_node!(conversation: conversation, name: "echo", tool_call_id: "tc_1")
    stream = DAG::NodeEventStream.new(node: task)

    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "echo",
        description: "Echo",
        parameters: {}
      ) do |_args, context:|
        _ = context
        AgentCore::Resources::Tools::ToolResult.success(text: "ok")
      end
    )

    runtime = runtime_with_registry(registry)
    executor = AgentCore::DAG::Executors::TaskExecutor.new

    result =
      with_runtime(runtime) do
        executor.execute(node: task, context: nil, stream: stream)
      end

    assert_equal DAG::Node::FINISHED, result.state

    events = task.graph.node_event_page_for(task.id, limit: 10, kinds: DAG::NodeEvent::ACTIVITY_EVENT_KINDS)

    assert_equal [DAG::NodeEvent::ACTIVITY_STARTED, DAG::NodeEvent::ACTIVITY_FINISHED], events.map { |event| event.fetch("kind") }
    assert_equal %w[running completed], events.map { |event| event.fetch("payload").fetch("status") }
    assert_equal ["task:#{task.id}", "task:#{task.id}"], events.map { |event| event.fetch("payload").fetch("activity_id") }
    assert_equal ["tool_call", "tool_call"], events.map { |event| event.fetch("payload").fetch("kind") }
    assert_equal [task.id, task.id], events.map { |event| event.fetch("payload").fetch("source_node_id") }
  end

  test "task execution emits activity_failed when the tool result is an error" do
    conversation = create_conversation!
    task = create_task_node!(conversation: conversation, name: "explode", tool_call_id: "tc_1")
    stream = DAG::NodeEventStream.new(node: task)

    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(
      AgentCore::Resources::Tools::Tool.new(
        name: "explode",
        description: "Explode",
        parameters: {}
      ) do |_args, context:|
        _ = context
        AgentCore::Resources::Tools::ToolResult.error(text: "boom")
      end
    )

    runtime = runtime_with_registry(registry)
    executor = AgentCore::DAG::Executors::TaskExecutor.new

    result =
      with_runtime(runtime) do
        executor.execute(node: task, context: nil, stream: stream)
      end

    assert_equal DAG::Node::FINISHED, result.state

    events = task.graph.node_event_page_for(task.id, limit: 10, kinds: DAG::NodeEvent::ACTIVITY_EVENT_KINDS)

    assert_equal [DAG::NodeEvent::ACTIVITY_STARTED, DAG::NodeEvent::ACTIVITY_FAILED], events.map { |event| event.fetch("kind") }
    assert_equal %w[running failed], events.map { |event| event.fetch("payload").fetch("status") }
    assert_equal "execution", events.last.fetch("payload").fetch("phase")
    assert_equal({ "error" => "boom" }, events.last.fetch("payload").fetch("data"))
  end

  private

    def create_task_node!(conversation:, name:, tool_call_id:)
      result = conversation.append_user_message!(content: "Hello")

      conversation.root_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        turn_id: result.fetch(:agent_node).turn_id,
        metadata: {},
        body_input: {
          "name" => name,
          "requested_name" => name,
          "tool_call_id" => tool_call_id,
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )
    end

    def runtime_with_registry(registry)
      AgentCore::DAG::Runtime.new(
        provider: Struct.new(:name).new("test-provider"),
        model: "dev/mock-model",
        tools_registry: registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    end

    def with_runtime(runtime)
      previous = AgentCore::DAG.runtime_resolver
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
      yield
    ensure
      AgentCore::DAG.runtime_resolver = previous
    end
end
