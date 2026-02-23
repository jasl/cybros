require "test_helper"

class DAG::SubagentToolsProfileEnforcementFlowTest < ActiveSupport::TestCase
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

  test "minimal profile denies tool calls as tool_not_in_profile and subagent_poll returns transcript preview" do
    parent = Conversation.create!
    parent_graph = parent.dag_graph
    parent_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    from_node = nil

    parent_graph.mutate!(turn_id: parent_turn_id) do |m|
      from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "parent",
          metadata: {},
        )
    end

    spawn_tool = Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_spawn" }
    poll_tool = Cybros::Subagent::Tools.build.find { |t| t.name == "subagent_poll" }

    spawn_ctx =
      AgentCore::ExecutionContext.new(
        run_id: parent_turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: parent_graph.id.to_s,
            node_id: from_node.id.to_s,
            lane_id: from_node.lane_id.to_s,
            turn_id: from_node.turn_id.to_s,
          },
          agent: { key: "main", policy_profile: "full", context_turns: 50 },
        },
      )

    spawn =
      spawn_tool.call(
        { "name" => "child", "prompt" => "child: hello", "policy_profile" => "minimal" },
        context: spawn_ctx,
      )

    refute spawn.error?, spawn.text

    child_id = JSON.parse(spawn.text).fetch("child_conversation_id")
    child = Conversation.find(child_id)
    child_graph = child.dag_graph

    initial_leaf = child_graph.leaf_nodes.where(lane_id: child_graph.main_lane.id).order(:id).last
    assert_equal Messages::AgentMessage.node_type_key, initial_leaf.node_type
    assert_equal DAG::Node::PENDING, initial_leaf.state

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "Calling tool",
                tool_calls: [
                  AgentCore::ToolCall.new(id: "tc_1", name: "echo", arguments: { "text" => "hi" }),
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
        AgentCore::Resources::Tools::ToolResult.success(text: "echo=#{args.fetch('text')}")
      end
    )

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
      claimed = DAG::Scheduler.claim_executable_nodes(graph: child_graph, limit: 10, claimed_by: "test")
      assert_equal [initial_leaf.id], claimed.map(&:id)

      DAG::Runner.run_node!(initial_leaf.id)

      task = child_graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).last
      unless task
        nodes_debug = child_graph.nodes.active.order(:id).pluck(:node_type, :state)
        leaf_debug = child_graph.nodes.find_by(id: initial_leaf.id)&.metadata
        flunk "expected a task node, nodes=#{nodes_debug.inspect} leaf_metadata=#{leaf_debug.inspect}"
      end
      assert_equal DAG::Node::FINISHED, task.state

      tool_result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))
      assert tool_result.error?
      assert_includes tool_result.text, "tool_not_in_profile"

      next_agent = child_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).order(:id).last
      assert next_agent, "expected next agent node"

      claimed = DAG::Scheduler.claim_executable_nodes(graph: child_graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "Done.", next_agent.body_output.fetch("content")

      tool_msg =
        provider.calls
          .fetch(1)
          .fetch(:messages)
          .find { |m| m.role == :tool_result && m.tool_call_id == "tc_1" }

      assert tool_msg, "expected tool_result message with tool_call_id tc_1"
      assert_includes tool_msg.text, "tool_not_in_profile"

      poll = poll_tool.call({ "child_conversation_id" => child.id.to_s, "limit_turns" => 10 }, context: nil)
      refute poll.error?, poll.text

      poll_payload = JSON.parse(poll.text)
      assert_equal "idle", poll_payload.fetch("status")
      assert_includes poll_payload.fetch("transcript_lines").join("\n"), "child: hello"
      assert_includes poll_payload.fetch("transcript_lines").join("\n"), "Done."

      assert_equal [], DAG::GraphAudit.scan(graph: child_graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end
end
