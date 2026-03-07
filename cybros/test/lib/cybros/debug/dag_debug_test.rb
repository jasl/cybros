require "test_helper"
require "ostruct"

class Cybros::CLI::DAGDebugTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class StubProvider < AgentCore::Resources::Provider::Base
    attr_reader :calls

    def initialize(content: "Hi!")
      @content = content
      @calls = []
    end

    def name = "stub"

    def last_call_metadata
      { "stub" => true, "calls" => @calls.length }
    end

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @calls << {
        messages: messages,
        model: model,
        tools: tools,
        stream: stream,
        options: options,
      }

      AgentCore::Resources::Provider::Response.new(
        message: AgentCore::Message.new(role: :assistant, content: @content),
        usage: AgentCore::Resources::Provider::Usage.new(
          input_tokens: 1,
          output_tokens: 1,
          cache_creation_tokens: 0,
          cache_read_tokens: 0,
        ),
        stop_reason: :end_turn,
      )
    end
  end

  class FakeResponsesClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def responses_stream(**kwargs)
      @calls << kwargs
      yield({ "type" => "response.output_text.delta", "delta" => "Hi" })
      yield({ "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } })
      nil
    end
  end

  class BodyOnlyResponsesClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def responses_stream(**kwargs)
      @calls << kwargs
      OpenStruct.new(
        body: {
          "output" => [
            {
              "type" => "message",
              "content" => [{ "type" => "output_text", "text" => "body only" }],
            },
          ],
          "usage" => { "input_tokens" => 3, "output_tokens" => 4 },
        },
      )
    end
  end

  class ErrorResponsesClient
    def responses_stream(**_kwargs)
      response =
        SimpleInference::Response.new(
          status: 400,
          headers: { "content-type" => "application/json" },
          body: { "error" => { "message" => "bad request" } },
          raw_body: "{\"error\":{\"message\":\"bad request\"}}",
        )

      raise SimpleInference::HTTPError.new("bad request", response: response)
    end
  end

  class StreamingProvider < AgentCore::Resources::Provider::Base
    def initialize
      @last_call_metadata = {}
    end

    def name = "streaming_stub"

    def last_call_metadata
      @last_call_metadata
    end

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      Enumerator.new do |y|
        y << AgentCore::StreamEvent::TextDelta.new(text: "Hel")
        y << AgentCore::StreamEvent::TextDelta.new(text: "lo")
        y << AgentCore::StreamEvent::MessageComplete.new(message: AgentCore::Message.new(role: :assistant, content: "Hello"))
        @last_call_metadata = { "final" => true, "chunks" => 2 }
        y << AgentCore::StreamEvent::Done.new(
          stop_reason: :end_turn,
          usage: AgentCore::Resources::Provider::Usage.new(
            input_tokens: 1,
            output_tokens: 1,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
          ),
        )
      end
    end
  end

  def build_runtime(provider:, llm_options: { stream: false })
    AgentCore::DAG::Runtime.new(
      provider: provider,
      model: "stub-model",
      tools_registry: AgentCore::Resources::Tools::Registry.new,
      tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
      llm_options: llm_options,
      instrumenter: AgentCore::Observability::NullInstrumenter.new,
    )
  end

  def with_runtime(runtime)
    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
    yield
  ensure
    AgentCore::DAG.runtime_resolver = original_runtime_resolver
  end

  def with_inline_jobs
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    yield
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def create_agent_pair(conversation:, agent_state:, user_content: "Hello", agent_metadata: {})
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: user_content,
          metadata: {},
        )

      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: agent_state,
          metadata: agent_metadata,
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    [user, agent]
  end

  test "inspect_node returns node basics retry chain and edge summaries" do
    clear_enqueued_jobs
    conversation = create_conversation!
    user, failed = create_agent_pair(conversation: conversation, agent_state: DAG::Node::ERRORED, agent_metadata: { "error" => "boom" })
    retried = failed.retry!

    summary = Cybros::CLI::DAGDebug.inspect_node(retried.id)

    assert_equal retried.id, summary.dig("node", "id")
    assert_equal conversation.id, summary.dig("conversation", "id")
    assert_equal [failed.id, retried.id], summary.fetch("retry_chain").map { |entry| entry.fetch("id") }
    assert summary.fetch("incoming_edges").any? { |edge| edge.fetch("from_node_id") == user.id }
  end

  test "turn_execution_snapshot exports projected execution diagnostics for a target node" do
    clear_enqueued_jobs
    conversation = create_conversation!
    turn = conversation.append_user_message!(content: "Hello", diagnostic_level: "debug")
    agent = turn.fetch(:agent_node)
    agent.mark_running!

    task =
      conversation.root_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "memory_search",
          "requested_name" => "memory_search",
          "tool_call_id" => "tc_1",
          "arguments" => {},
          "arguments_summary" => "{}",
        },
      )

    DAG::NodeEventStream.new(node: task).activity_started!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
      diagnostic_level: "debug",
      data: { "executor" => "task_executor" },
    )

    snapshot = Cybros::CLI::DAGDebug.turn_execution_snapshot(agent.id)
    expected = conversation.turn_execution_for_node_id(agent.id)

    assert_equal expected, snapshot
    assert_equal "debug", snapshot.fetch("diagnostic_level")
    assert_equal "task:#{task.id}", snapshot.dig("activities", 0, "activity_id")
    assert_equal "task_executor", snapshot.dig("activities", 0, "diagnostics", "last_event_data", "executor")
  end

  test "context_snapshot returns context closure and built prompt summary" do
    clear_enqueued_jobs
    conversation = create_conversation!
    user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "What model are you?")
    provider = StubProvider.new
    runtime = build_runtime(provider: provider)

    snapshot = nil
    with_runtime(runtime) do
      snapshot = Cybros::CLI::DAGDebug.context_snapshot(agent.id)
    end

    assert_equal agent.id, snapshot.dig("node", "id")
    assert_equal user.id, snapshot.fetch("context").first.fetch("node_id")
    assert_equal user.id, snapshot.fetch("closure").first.fetch("node_id")
    assert snapshot.dig("built_prompt", "system_prompt").to_s.present?
    assert_equal "user", snapshot.dig("built_prompt", "messages", 0, "role")
  end

  test "capture_node records final provider call and execution summary" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "Hello from capture")
    provider = StubProvider.new(content: "Captured")
    runtime = build_runtime(provider: provider)

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true)
    end

    assert_equal agent.id, capture.dig("target_node", "id")
    assert_equal "finished", capture.dig("execution", "result_state")
    assert_equal DAG::Node::FINISHED, agent.reload.state
    assert_equal 1, capture.fetch("captured_calls").length
    first_call = capture.fetch("captured_calls").first
    assert_equal "stub-model", first_call.fetch("model")
    assert_equal true, first_call.fetch("provider_metadata").fetch("stub")
    assert_equal "system", first_call.fetch("messages").first.fetch("role")
  end

  test "capture_node without execute includes context snapshot" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "Hello from snapshot")
    provider = StubProvider.new
    runtime = build_runtime(provider: provider)

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: false)
    end

    assert_equal "snapshot_only", capture.dig("execution", "mode")
    assert_equal agent.id, capture.dig("context_snapshot", "node", "id")
    assert_equal 2, capture.dig("context_snapshot", "context").length
  end

  test "capture_node retry_first reports retry errors without raising" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::FINISHED, user_content: "Hello from retry-first")
    provider = StubProvider.new
    runtime = build_runtime(provider: provider)

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true, retry_first: true)
    end

    assert_equal agent.id, capture.dig("target_node", "id")
    assert_equal "retry_inline", capture.dig("execution", "mode")
    assert_equal "not_retryable", capture.dig("execution", "error")
  end

  test "capture_node refuses safe execution for running nodes" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::RUNNING, user_content: "Hello from running")
    provider = StubProvider.new
    runtime = build_runtime(provider: provider)

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true)
    end

    assert_equal "snapshot_only", capture.dig("execution", "mode")
    assert_includes capture.dig("execution", "error").to_s, "Refusing to execute this node inline"
    refute_includes capture.dig("execution", "error").to_s, "--unsafe-direct-execute"
    assert_equal 0, capture.fetch("captured_calls").length
  end

  test "capture_node refuses inline execution for pending but unclaimable nodes" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "Hello from blocked pending")
    provider = StubProvider.new
    runtime = build_runtime(provider: provider)

    blocker = nil
    conversation.dag_graph.mutate! do |m|
      blocker =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )
      m.create_edge(from_node: blocker, to_node: agent, edge_type: DAG::Edge::DEPENDENCY)
    end

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true)
    end

    assert_equal "snapshot_only", capture.dig("execution", "mode")
    assert_includes capture.dig("execution", "error").to_s, "Refusing to execute this node inline"
    assert_equal DAG::Node::PENDING, agent.reload.state
    assert_equal 0, capture.fetch("captured_calls").length
  end

  test "capture_node unsafe_direct_execute is refused because direct executor state is incomplete" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::RUNNING, user_content: "Hello from unsafe")
    provider = StreamingProvider.new
    runtime = build_runtime(provider: provider, llm_options: { stream: true })

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true, unsafe_direct_execute: true)
    end

    assert_equal "snapshot_only", capture.dig("execution", "mode")
    assert_includes capture.dig("execution", "error").to_s, "Direct executor mode is not supported"
  end

  test "capture_node retry_first creates and snapshots the retry target" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::ERRORED, user_content: "Hello from retry target")
    provider = StubProvider.new(content: "Retry capture succeeded")
    runtime = build_runtime(provider: provider)

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: false, retry_first: true)
    end

    assert_equal agent.id, capture.dig("source_node", "id")
    assert_equal agent.id, capture.dig("target_node", "retry_of_id")
    assert_equal "pending", capture.dig("target_node", "state")
  end

  test "capture_node records wire calls for simple inference responses providers" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "Hello from wire capture")
    client = FakeResponsesClient.new
    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
        request_defaults: { reasoning_effort: :high },
      )
    runtime = build_runtime(provider: provider, llm_options: { stream: true })

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true)
    end

    assert_equal 1, capture.fetch("wire_calls").length
    wire_call = capture.fetch("wire_calls").first
    wire_payload = wire_call.fetch("payload")
    assert_equal "responses_stream", wire_call.fetch("method")
    assert_equal ["response.output_text.delta", "response.completed"], wire_call.fetch("events").map { |event| event.fetch("type") }
    assert_equal false, wire_payload.fetch("store")
    assert_equal({ "effort" => "high" }, wire_payload.fetch("reasoning"))
    assert wire_payload.fetch("instructions").to_s.present?
  end

  test "capture_node records stream events and final provider metadata for streaming providers" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "Hello from stream capture")
    provider = StreamingProvider.new
    runtime = build_runtime(provider: provider, llm_options: { stream: true })

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true)
    end

    call = capture.fetch("captured_calls").first
    assert_equal ["text_delta", "text_delta", "message_complete", "done"], call.fetch("stream_events").map { |event| event.fetch("type") }
    assert_equal true, call.dig("provider_metadata", "final")
    assert_equal 2, call.dig("provider_metadata", "chunks")
  end

  test "capture_node records raw streaming response summaries when no SSE events are yielded" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "Hello from body only")
    client = BodyOnlyResponsesClient.new
    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )
    runtime = build_runtime(provider: provider, llm_options: { stream: true })

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true)
    end

    wire_call = capture.fetch("wire_calls").first
    assert_equal "responses_stream", wire_call.fetch("method")
    assert_equal [], wire_call.fetch("events", [])
    assert_equal "body only", wire_call.dig("response", "body", "output", 0, "content", 0, "text")
  end

  test "capture_node records raw streaming error summaries when the client raises http error" do
    clear_enqueued_jobs
    conversation = create_conversation!
    _user, agent = create_agent_pair(conversation: conversation, agent_state: DAG::Node::PENDING, user_content: "Hello from wire error")
    client = ErrorResponsesClient.new
    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )
    runtime = build_runtime(provider: provider, llm_options: { stream: true })

    capture = nil
    with_runtime(runtime) do
      capture = Cybros::CLI::DAGDebug.capture_node(agent.id, execute: true)
    end

    wire_call = capture.fetch("wire_calls").first
    assert_equal "responses_stream", wire_call.fetch("method")
    assert_equal 400, wire_call.dig("error", "status")
    assert_equal({ "error" => { "message" => "bad request" } }, wire_call.dig("error", "body"))
  end

  test "retry_node_inline returns created node and final terminal state" do
    clear_enqueued_jobs
    clear_performed_jobs

    conversation = create_conversation!
    _user, failed = create_agent_pair(conversation: conversation, agent_state: DAG::Node::ERRORED, agent_metadata: { "error" => "boom" })
    provider = StubProvider.new(content: "Retry succeeded")
    runtime = build_runtime(provider: provider)

    result = nil
    with_runtime(runtime) do
      with_inline_jobs do
        result = Cybros::CLI::DAGDebug.retry_node_inline(failed.id)
      end
    end

    assert_equal failed.id, result.dig("source_node", "id")
    assert_equal "finished", result.dig("created_node", "state")
    assert_equal "Retry succeeded", result.dig("created_node", "body_output", "content")
  end

  test "smoke_conversation_inline creates a temporary conversation and finishes the agent node" do
    clear_enqueued_jobs
    clear_performed_jobs

    conversation = create_conversation!
    provider = StubProvider.new(content: "Smoke succeeded")
    runtime = build_runtime(provider: provider)

    result = nil
    assert_no_difference -> { Conversation.count } do
      with_runtime(runtime) do
        result =
          Cybros::CLI::DAGDebug.smoke_conversation_inline(
            conversation_id: conversation.id,
            prompt: "Smoke hello",
            model_ref: "dev/mock-model",
          )
      end
    end

    assert_equal "finished", result.dig("agent_node", "state")
    assert_equal "Smoke succeeded", result.dig("agent_node", "body_output", "content")
    assert_equal "Smoke hello", result.dig("user_node", "body_input", "content")
    assert_equal true, result.dig("conversation", "ephemeral")
  end
end
