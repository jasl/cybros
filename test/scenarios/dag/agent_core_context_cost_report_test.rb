# frozen_string_literal: true

require "test_helper"

class DAG::AgentCoreContextCostReportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(response:)
      @response = response
      @calls = []
    end

    attr_reader :calls

    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @calls << { messages: messages, model: model, tools: tools, stream: stream, options: options }
      @response
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "context_cost report includes prune_tool_outputs decision when pruning makes prompt fit" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    long_tool_output = "x" * 2_000

    t1 = "0194f3c0-0000-7000-8000-00000000d200"
    t2 = "0194f3c0-0000-7000-8000-00000000d201"
    t3 = "0194f3c0-0000-7000-8000-00000000d202"

    u1 = a1 = task1 = u2 = a2 = u3 = a3 = nil

    graph.mutate! do |m|
      u1 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t1, content: "u1", metadata: {})
      a1 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t1, body_output: { "content" => "a1" }, metadata: {})
      task1 =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          turn_id: t1,
          metadata: {},
          body_input: {
            "tool_call_id" => "tc_1",
            "name" => "echo",
            "arguments" => {},
          },
          body_output: {
            "result" => AgentCore::Resources::Tools::ToolResult.success(text: long_tool_output).to_h,
          },
        )

      u2 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t2, content: "u2", metadata: {})
      a2 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t2, body_output: { "content" => "a2" }, metadata: {})

      u3 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t3, content: "u3", metadata: {})
      a3 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, turn_id: t3, metadata: {})

      m.create_edge(from_node: u1, to_node: a1, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: a1, to_node: task1, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task1, to_node: u2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u2, to_node: a2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: a2, to_node: u3, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u3, to_node: a3, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        response: AgentCore::Resources::Provider::Response.new(
          message: AgentCore::Message.new(role: :assistant, content: "Ok."),
          stop_reason: :end_turn,
        ),
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 350,
        reserved_output_tokens: 0,
        token_counter: AgentCore::Resources::TokenCounter::Heuristic.new(chars_per_token: 1.0, non_ascii_chars_per_token: 1.0),
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [a3.id], claimed.map(&:id)

      DAG::Runner.run_node!(a3.id)

      a3.reload
      assert_equal DAG::Node::FINISHED, a3.state

      # Pruned prompt should still include the tool result message and tool_call_id.
      sent_messages = provider.calls.fetch(0).fetch(:messages)
      tool_msg = sent_messages.find { |m| m.role == :tool_result && m.tool_call_id == "tc_1" }
      assert tool_msg, "expected tool_result message with tool_call_id tc_1"
      assert tool_msg.text.start_with?("[Trimmed tool output"), tool_msg.text

      ctx_cost = a3.metadata.fetch("context_cost")
      decisions = ctx_cost.fetch("decisions")
      assert decisions.any? { |d| d["type"] == "prune_tool_outputs" }

      assert_equal 3, ctx_cost.fetch("limit_turns")
      refute decisions.any? { |d| d["type"] == "shrink_turns" }
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context_cost is recorded on ContextWindowExceededError and provider is not called" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    t1 = "0194f3c0-0000-7000-8000-00000000d210"

    u1 = a1 = nil

    graph.mutate! do |m|
      u1 =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          turn_id: t1,
          content: "u1 " + ("x" * 500),
          metadata: {},
        )

      a1 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, turn_id: t1, metadata: {})

      m.create_edge(from_node: u1, to_node: a1, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        response: AgentCore::Resources::Provider::Response.new(
          message: AgentCore::Message.new(role: :assistant, content: "Ok."),
          stop_reason: :end_turn,
        ),
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 50,
        reserved_output_tokens: 0,
        token_counter: AgentCore::Resources::TokenCounter::Heuristic.new(chars_per_token: 1.0, non_ascii_chars_per_token: 1.0),
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [a1.id], claimed.map(&:id)

      DAG::Runner.run_node!(a1.id)

      a1.reload
      assert_equal DAG::Node::ERRORED, a1.state
      assert_empty provider.calls, "provider should not be called when prompt cannot fit"

      ctx_cost = a1.metadata.fetch("context_cost")
      assert_equal 50, ctx_cost.fetch("context_window_tokens")
      assert_equal 50, ctx_cost.fetch("limit")
      assert ctx_cost.fetch("estimated_tokens").fetch("total").to_i > 50
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "context_cost records multiple prune_tool_outputs attempts when shrinking turns" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    long_tool_output = "x" * 2_000
    long_assistant = "y" * 2_000

    t1 = "0194f3c0-0000-7000-8000-00000000d220"
    t2 = "0194f3c0-0000-7000-8000-00000000d221"
    t3 = "0194f3c0-0000-7000-8000-00000000d222"
    t4 = "0194f3c0-0000-7000-8000-00000000d223"
    t5 = "0194f3c0-0000-7000-8000-00000000d224"

    u1 = a1 = task1 = u2 = a2 = task2 = u3 = a3 = task3 = u4 = a4 = u5 = a5 = nil

    graph.mutate! do |m|
      u1 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t1, content: "u1", metadata: {})
      a1 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t1, body_output: { "content" => long_assistant }, metadata: {})
      task1 =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          turn_id: t1,
          metadata: {},
          body_input: {
            "tool_call_id" => "tc_1",
            "name" => "echo",
            "arguments" => {},
          },
          body_output: {
            "result" => AgentCore::Resources::Tools::ToolResult.success(text: long_tool_output).to_h,
          },
        )

      u2 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t2, content: "u2", metadata: {})
      a2 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t2, body_output: { "content" => "a2" }, metadata: {})
      task2 =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          turn_id: t2,
          metadata: {},
          body_input: {
            "tool_call_id" => "tc_2",
            "name" => "echo",
            "arguments" => {},
          },
          body_output: {
            "result" => AgentCore::Resources::Tools::ToolResult.success(text: long_tool_output).to_h,
          },
        )

      u3 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t3, content: "u3", metadata: {})
      a3 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t3, body_output: { "content" => "a3" }, metadata: {})
      task3 =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          turn_id: t3,
          metadata: {},
          body_input: {
            "tool_call_id" => "tc_3",
            "name" => "echo",
            "arguments" => {},
          },
          body_output: {
            "result" => AgentCore::Resources::Tools::ToolResult.success(text: long_tool_output).to_h,
          },
        )

      u4 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t4, content: "u4", metadata: {})
      a4 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t4, body_output: { "content" => "a4" }, metadata: {})

      u5 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, turn_id: t5, content: "u5", metadata: {})
      a5 = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, turn_id: t5, metadata: {})

      m.create_edge(from_node: u1, to_node: a1, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: a1, to_node: task1, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task1, to_node: u2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u2, to_node: a2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: a2, to_node: task2, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task2, to_node: u3, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u3, to_node: a3, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: a3, to_node: task3, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task3, to_node: u4, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u4, to_node: a4, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: a4, to_node: u5, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: u5, to_node: a5, edge_type: DAG::Edge::SEQUENCE)
    end

    provider =
      StubProvider.new(
        response: AgentCore::Resources::Provider::Response.new(
          message: AgentCore::Message.new(role: :assistant, content: "Ok."),
          stop_reason: :end_turn,
        ),
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 2_000,
        reserved_output_tokens: 0,
        token_counter: AgentCore::Resources::TokenCounter::Heuristic.new(chars_per_token: 1.0, non_ascii_chars_per_token: 1.0),
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [a5.id], claimed.map(&:id)

      DAG::Runner.run_node!(a5.id)

      a5.reload
      assert_equal DAG::Node::FINISHED, a5.state

      ctx_cost = a5.metadata.fetch("context_cost")
      decisions = ctx_cost.fetch("decisions")
      prune_attempts =
        decisions
          .select { |d| d["type"] == "prune_tool_outputs" }
          .map { |d| d["attempt"] }

      assert_equal [1, 2], prune_attempts
      assert decisions.any? { |d| d["type"] == "shrink_turns" && d["limit_turns"] == 4 }

      sent_messages = provider.calls.fetch(0).fetch(:messages)
      refute sent_messages.any? { |m| m.role == :tool_result && m.tool_call_id == "tc_1" }

      tc2 = sent_messages.find { |m| m.role == :tool_result && m.tool_call_id == "tc_2" }
      tc3 = sent_messages.find { |m| m.role == :tool_result && m.tool_call_id == "tc_3" }
      assert tc2, "expected tool_result message with tool_call_id tc_2"
      assert tc3, "expected tool_result message with tool_call_id tc_3"
      assert tc2.text.start_with?("[Trimmed tool output"), tc2.text
      assert tc3.text.start_with?("[Trimmed tool output"), tc3.text
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end
end
