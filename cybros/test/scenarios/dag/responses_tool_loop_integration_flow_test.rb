require "test_helper"
require "ostruct"

class DAG::ResponsesToolLoopIntegrationFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class QueuedResponsesAdapter < SimpleInference::HTTPAdapter
    def initialize(call_entries:, stream_entries: [])
      @call_entries = Array(call_entries)
      @stream_entries = Array(stream_entries)
      @calls = []
    end

    attr_reader :calls

    def call(env)
      @calls << env
      entry = @call_entries.shift
      raise "unexpected adapter.call (no remaining responses)" if entry.nil?
      raise entry if entry.is_a?(Exception)
      entry
    end

    def call_stream(env)
      @calls << env
      entry = @stream_entries.shift
      raise "unexpected adapter.call_stream (no remaining responses)" if entry.nil?
      raise entry if entry.is_a?(Exception)

      if entry.is_a?(Hash) && entry.key?(:response)
        Array(entry[:chunks]).each do |chunk|
          raise chunk if chunk.is_a?(Exception)
          yield chunk
        end
        entry[:response]
      else
        Array(entry).each do |chunk|
          raise chunk if chunk.is_a?(Exception)
          yield chunk
        end
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end
  end

  class FakeResponsesClient
    def initialize(responses:, stream_events: [])
      @responses = Array(responses)
      @stream_events = Array(stream_events)
      @calls = []
    end

    attr_reader :calls

    def responses(**kwargs)
      @calls << kwargs
      resp = @responses.shift
      raise "unexpected client.responses call (no remaining responses)" unless resp
      raise resp if resp.is_a?(Exception)
      resp
    end

    def responses_stream(**kwargs)
      @calls << kwargs
      entry = @stream_events.shift
      raise "unexpected client.responses_stream call (no remaining responses)" if entry.nil?
      raise entry if entry.is_a?(Exception)

      Array(entry).each do |event|
        raise event if event.is_a?(Exception)
        yield event
      end
      nil
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "responses provider supports starting tool loop and sending function_call_output followup" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d1ff"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    adapter =
      QueuedResponsesAdapter.new(
        call_entries: [
          responses_http_success(output_items: [responses_function_call_item(text: "hi")]),
          responses_http_success(output_text: "All done.", output_items: [responses_assistant_message_item(text: "All done.")]),
        ],
      )

    client = build_responses_protocol_client(adapter)
    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)

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
        model: "gpt-5.4",
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

      agent.reload
      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 1, tasks.length

      next_agent =
        graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal tasks.map(&:id), claimed.map(&:id)
      tasks.each { |task| DAG::Runner.run_node!(task.id) }

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "All done.", next_agent.body_output.fetch("content")

      assert_equal 2, adapter.calls.size
      tools1 = parsed_request_body(adapter.calls.first).fetch("tools")
      assert tools1.is_a?(Array)

      input2 = parsed_request_body(adapter.calls.second).fetch("input")
      assert input2.is_a?(Array)

      fn_call = input2.find { |i| i.is_a?(Hash) && i["type"].to_s == "function_call" }
      refute_nil fn_call
      assert_equal "call_1", fn_call["call_id"]
      assert_equal "echo", fn_call["name"]
      assert_includes fn_call["arguments"].to_s, "hi"

      fn_out = input2.find { |i| i.is_a?(Hash) && i["type"].to_s == "function_call_output" }
      refute_nil fn_out
      assert_equal "call_1", fn_out["call_id"]
      assert_includes fn_out["output"].to_s, "echo=hi"
      assert_operator input2.index(fn_call), :<, input2.index(fn_out)
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses provider retries a retryable followup failure and completes the same turn" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d200"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    adapter =
      QueuedResponsesAdapter.new(
        call_entries: [
          responses_http_success(output_items: [responses_function_call_item(text: "hi")]),
          responses_http_error(status: 429, message: "rate limited"),
          responses_http_success(output_text: "Recovered.", output_items: [responses_assistant_message_item(text: "Recovered.")]),
        ],
      )

    client = build_responses_protocol_client(adapter)
    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    tools_registry = build_echo_tools_registry
    runtime = AgentCore::DAG::Runtime.new(provider: provider, model: "gpt-5.4", tools_registry: tools_registry, tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new, llm_options: { stream: false }, instrumenter: AgentCore::Observability::NullInstrumenter.new)

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

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "Recovered.", next_agent.body_output.fetch("content")
      assert_equal 3, adapter.calls.size

      followup_input_1 = parsed_request_body(adapter.calls.second).fetch("input")
      followup_input_2 = parsed_request_body(adapter.calls.third).fetch("input")
      assert_equal followup_input_1, followup_input_2
      fn_call = followup_input_1.find { |i| i.is_a?(Hash) && i["type"].to_s == "function_call" }
      fn_out = followup_input_1.find { |i| i.is_a?(Hash) && i["type"].to_s == "function_call_output" }
      refute_nil fn_call
      refute_nil fn_out
      assert_operator followup_input_1.index(fn_call), :<, followup_input_1.index(fn_out)

      recovery = next_agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 1, recovery.fetch("recovered")
      assert_equal 0, recovery.fetch("failed")
      assert_equal false, recovery.fetch("exhausted")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses provider exhausts retryable followup recovery attempts and leaves next agent errored" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d201"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    adapter =
      QueuedResponsesAdapter.new(
        call_entries: [
          responses_http_success(output_items: [responses_function_call_item(text: "hi")]),
          responses_http_error(status: 429, message: "rate limited"),
          responses_http_error(status: 429, message: "still rate limited"),
        ],
      )

    client = build_responses_protocol_client(adapter)
    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    tools_registry = build_echo_tools_registry
    runtime = AgentCore::DAG::Runtime.new(provider: provider, model: "gpt-5.4", tools_registry: tools_registry, tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new, llm_options: { stream: false }, instrumenter: AgentCore::Observability::NullInstrumenter.new)

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

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::ERRORED, next_agent.state
      assert_equal 3, adapter.calls.size

      followup_input_1 = parsed_request_body(adapter.calls.second).fetch("input")
      followup_input_2 = parsed_request_body(adapter.calls.third).fetch("input")
      assert_equal followup_input_1, followup_input_2

      recovery = next_agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 0, recovery.fetch("recovered")
      assert_equal 1, recovery.fetch("failed")
      assert_equal true, recovery.fetch("exhausted")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses provider mixed retryable then non-retryable followup failure does not mark recovery exhausted" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d202"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    adapter =
      QueuedResponsesAdapter.new(
        call_entries: [
          responses_http_success(output_items: [responses_function_call_item(text: "hi")]),
          responses_http_error(status: 429, message: "rate limited"),
          responses_http_error(status: 400, message: "bad request"),
        ],
      )

    client = build_responses_protocol_client(adapter)
    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    tools_registry = build_echo_tools_registry
    runtime = AgentCore::DAG::Runtime.new(provider: provider, model: "gpt-5.4", tools_registry: tools_registry, tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new, llm_options: { stream: false }, instrumenter: AgentCore::Observability::NullInstrumenter.new)

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

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::ERRORED, next_agent.state
      assert_equal 3, adapter.calls.size

      followup_input_1 = parsed_request_body(adapter.calls.second).fetch("input")
      followup_input_2 = parsed_request_body(adapter.calls.third).fetch("input")
      assert_equal followup_input_1, followup_input_2

      recovery = next_agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 0, recovery.fetch("recovered")
      assert_equal 1, recovery.fetch("failed")
      assert_equal false, recovery.fetch("exhausted")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses provider non-retryable followup configuration error does not retry" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d203"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    adapter =
      QueuedResponsesAdapter.new(
        call_entries: [
          responses_http_success(output_items: [responses_function_call_item(text: "hi")]),
          SimpleInference::ConfigurationError.new("bad config"),
        ],
      )

    client = build_responses_protocol_client(adapter)
    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    tools_registry = build_echo_tools_registry
    runtime = AgentCore::DAG::Runtime.new(provider: provider, model: "gpt-5.4", tools_registry: tools_registry, tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new, llm_options: { stream: false }, instrumenter: AgentCore::Observability::NullInstrumenter.new)

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

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::ERRORED, next_agent.state
      assert_equal 2, adapter.calls.size
      assert_nil next_agent.metadata.dig("llm_call", "recovery")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses streaming retries a recoverable bootstrap failure before output and completes" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d204"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    client =
      FakeResponsesClient.new(
        responses: [],
        stream_events: [
          SimpleInference::TimeoutError.new("timed out"),
          [
            { "type" => "response.output_text.delta", "delta" => "Recovered" },
            { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
          ],
        ],
      )

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "gpt-5.4",
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
      assert_equal "Recovered", agent.body_output.fetch("content")
      assert_equal 2, client.calls.size

      recovery = agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 1, recovery.fetch("recovered")
      assert_equal false, recovery.fetch("exhausted")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses streaming retries a retryable provider http failure before output and completes" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d204a"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    adapter =
      QueuedResponsesAdapter.new(
        call_entries: [],
        stream_entries: [
          { response: responses_http_error(status: 429, message: "rate limited") },
          {
            chunks: [
              responses_sse_payload(
                [
                  { "type" => "response.output_text.delta", "delta" => "Recovered via 429" },
                  { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
                ],
              ),
            ],
            response: { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil },
          },
        ],
      )

    client = build_responses_protocol_client(adapter)
    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "gpt-5.4",
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
      assert_equal "Recovered via 429", agent.body_output.fetch("content")
      assert_equal 2, adapter.calls.size

      recovery = agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 1, recovery.fetch("recovered")
      assert_equal false, recovery.fetch("exhausted")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses streaming non-retryable provider error before output does not retry" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d205"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    http_response =
      SimpleInference::Response.new(
        status: 400,
        headers: { "content-type" => "application/json" },
        body: { "error" => { "message" => "bad request" } },
        raw_body: "{\"error\":{\"message\":\"bad request\"}}",
      )

    client =
      FakeResponsesClient.new(
        responses: [],
        stream_events: [
          SimpleInference::HTTPError.new("bad request", response: http_response),
          [
            { "type" => "response.output_text.delta", "delta" => "Should not retry" },
            { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
          ],
        ],
      )

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "gpt-5.4",
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
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 1, client.calls.size
      assert_nil agent.metadata.dig("llm_call", "recovery")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses streaming failure after output delta does not retry automatically" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d206"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    client =
      FakeResponsesClient.new(
        responses: [],
        stream_events: [
          [
            { "type" => "response.output_text.delta", "delta" => "Hel" },
            SimpleInference::TimeoutError.new("timed out"),
          ],
          [
            { "type" => "response.output_text.delta", "delta" => "Should not retry" },
            { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
          ],
        ],
      )

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "gpt-5.4",
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
      assert_equal DAG::Node::ERRORED, agent.state
      assert_equal 1, client.calls.size
      assert_equal true, agent.metadata.dig("stream", "output_committed")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "responses streaming followup after function_call_output retries retryable http failure and completes" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d207"

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Do tools", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    adapter =
      QueuedResponsesAdapter.new(
        call_entries: [],
        stream_entries: [
          {
            chunks: [
              responses_sse_payload(
                [
                  {
                    "type" => "response.output_item.added",
                    "output_index" => 0,
                    "sequence_number" => 1,
                    "item" => {
                      "type" => "function_call",
                      "id" => "item_1",
                      "call_id" => "call_1",
                      "name" => "echo",
                      "arguments" => "",
                    },
                  },
                  {
                    "type" => "response.function_call_arguments.done",
                    "item_id" => "item_1",
                    "output_index" => 0,
                    "sequence_number" => 2,
                    "name" => "echo",
                    "arguments" => "{\"text\":\"hi\"}",
                  },
                  { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
                ],
              ),
            ],
            response: { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil },
          },
          { response: responses_http_error(status: 429, message: "rate limited") },
          {
            chunks: [
              responses_sse_payload(
                [
                  { "type" => "response.output_text.delta", "delta" => "Recovered streamed followup" },
                  { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
                ],
              ),
            ],
            response: { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil },
          },
        ],
      )

    client = build_responses_protocol_client(adapter)
    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "gpt-5.4",
        tools_registry: build_echo_tools_registry,
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

      task = graph.nodes.active.where(node_type: Messages::Task.node_type_key).sole
      next_agent = graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).where.not(id: agent.id).sole

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [task.id], claimed.map(&:id)
      DAG::Runner.run_node!(task.id)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [next_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(next_agent.id)

      next_agent.reload
      assert_equal DAG::Node::FINISHED, next_agent.state
      assert_equal "Recovered streamed followup", next_agent.body_output.fetch("content")
      assert_equal 3, adapter.calls.size

      recovery = next_agent.metadata.dig("llm_call", "recovery")
      refute_nil recovery
      assert_equal 1, recovery.fetch("attempts")
      assert_equal 1, recovery.fetch("recovered")
      assert_equal false, recovery.fetch("exhausted")
      assert_graph_clean(graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  private

    def build_responses_protocol_client(adapter)
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )
    end

    def responses_http_success(output_items:, output_text: "", usage: { "input_tokens" => 1, "output_tokens" => 1 })
      {
        status: 200,
        headers: { "content-type" => "application/json" },
        body: JSON.generate({ "output" => output_items, "usage" => usage, "output_text" => output_text }),
      }
    end

    def responses_http_error(status:, message:)
      {
        status: status,
        headers: { "content-type" => "application/json" },
        body: JSON.generate({ "error" => { "message" => message } }),
      }
    end

    def responses_function_call_item(text:)
      {
        "type" => "function_call",
        "id" => "item_1",
        "call_id" => "call_1",
        "name" => "echo",
        "arguments" => "{\"text\":\"#{text}\"}",
      }
    end

    def responses_assistant_message_item(text:)
      {
        "type" => "message",
        "role" => "assistant",
        "content" => [{ "type" => "output_text", "text" => text }],
      }
    end

    def parsed_request_body(call_env)
      JSON.parse(call_env.fetch(:body))
    end

    def responses_sse_payload(events)
      payload = Array(events).map { |event| "data: #{JSON.generate(event)}\n\n" }.join
      "#{payload}data: [DONE]\n\n"
    end

    def assert_graph_clean(graph)
      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    end

    def build_echo_tools_registry
      AgentCore::Resources::Tools::Registry.new.tap do |tools_registry|
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
      end
    end
end
