require "test_helper"
require "ostruct"

class SimpleInferenceProviderResponsesTest < ActiveSupport::TestCase
  class FakeResponsesClient
    attr_reader :calls

    def initialize(events:)
      @events = events
      @calls = []
    end

    def responses(**kwargs)
      @calls << kwargs
      OpenStruct.new(
        output_text: "",
        usage: { "input_tokens" => 1, "output_tokens" => 2 },
        output_items: [
          {
            "type" => "function_call",
            "id" => "item_1",
            "call_id" => "call_1",
            "name" => "echo",
            "arguments" => "{\"text\":\"hello\"}",
          },
        ],
        response: OpenStruct.new(body: { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } }),
      )
    end

    def responses_stream(**_kwargs)
      @calls << _kwargs
      @events.each { |e| yield e }
      nil
    end
  end

  class RaisingResponsesClient
    def initialize(error:)
      @error = error
      @calls = []
    end

    attr_reader :calls

    def responses(**kwargs)
      @calls << kwargs
      raise "responses should not be called in streaming tests"
    end

    def responses_stream(**kwargs)
      @calls << kwargs
      raise @error
    end
  end

  test "streaming responses lifts system messages into top-level instructions" do
    client =
      FakeResponsesClient.new(
        events: [
          { "type" => "response.output_text.delta", "delta" => "Hi" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    _events =
      provider.chat(
        messages: [
          AgentCore::Message.new(role: :system, content: "Be helpful."),
          AgentCore::Message.new(role: :user, content: "hi"),
        ],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    request = client.calls.fetch(0)
    assert_equal "Be helpful.", request[:instructions]
    assert_equal 1, request[:input].length
    assert_equal "user", request[:input].first.fetch("role")
    assert_equal [{ "type" => "input_text", "text" => "hi" }], request[:input].first.fetch("content")
  end

  test "streaming responses defaults store to false" do
    client =
      FakeResponsesClient.new(
        events: [
          { "type" => "response.output_text.delta", "delta" => "Hi" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    provider.chat(
      messages: [AgentCore::Message.new(role: :user, content: "hi")],
      model: "m",
      tools: nil,
      stream: true,
    ).to_a

    request = client.calls.fetch(0)
    assert_equal false, request[:store]
  end

  test "streaming responses maps reasoning_effort into reasoning payload" do
    client =
      FakeResponsesClient.new(
        events: [
          { "type" => "response.output_text.delta", "delta" => "Hi" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
        request_defaults: { reasoning_effort: :high },
      )

    provider.chat(
      messages: [AgentCore::Message.new(role: :user, content: "hi")],
      model: "m",
      tools: nil,
      stream: true,
    ).to_a

    request = client.calls.fetch(0)
    assert_equal({ effort: :high }, request[:reasoning])
    assert_nil request[:reasoning_effort]
  end

  test "streaming responses yields text deltas and done" do
    client =
      FakeResponsesClient.new(
        events: [
          { "type" => "response.output_text.delta", "delta" => "Hel" },
          { "type" => "response.output_text.delta", "delta" => "lo" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    enum =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      )

    events = enum.to_a
    deltas = events.select { |e| e.is_a?(AgentCore::StreamEvent::TextDelta) }.map(&:text).join
    assert_equal "Hello", deltas

    done = events.find { |e| e.is_a?(AgentCore::StreamEvent::Done) }
    assert done
    assert_equal 1, done.usage.input_tokens
    assert_equal 2, done.usage.output_tokens
  end

  test "streaming responses maps incomplete max_output_tokens to max_tokens stop reason" do
    client =
      FakeResponsesClient.new(
        events: [
          { "type" => "response.output_text.delta", "delta" => "Partial" },
          {
            "type" => "response.completed",
            "response" => {
              "status" => "incomplete",
              "incomplete_details" => { "reason" => "max_output_tokens" },
              "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
            },
          },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    done = events.find { |e| e.is_a?(AgentCore::StreamEvent::Done) }
    assert done
    assert_equal :max_tokens, done.stop_reason
  end

  test "non-streaming responses encodes image input using responses content types" do
    captured = []
    client =
      Class.new do
        define_method(:initialize) { |calls| @calls = calls }

        define_method(:responses) do |**kwargs|
          @calls << kwargs
          OpenStruct.new(
            output_text: "ok",
            output_items: [],
            usage: { "input_tokens" => 1, "output_tokens" => 1 },
            response: OpenStruct.new(body: { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }),
          )
        end
      end.new(captured)

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    message =
      AgentCore::Message.new(
        role: :user,
        content: [
          AgentCore::TextContent.new(text: "what is in this image?"),
          AgentCore::ImageContent.new(source_type: :base64, data: "AA==", media_type: "image/png"),
        ],
      )

    provider.chat(messages: [message], model: "m", stream: false)

    input = captured.first.fetch(:input)
    assert_equal "user", input.first.fetch("role")
    content = input.first.fetch("content")
    assert_equal(
      [
        { "type" => "input_text", "text" => "what is in this image?" },
        { "type" => "input_image", "image_url" => "data:image/png;base64,AA==" },
      ],
      content,
    )
  end

  test "non-streaming responses supports function_call output items" do
    client = FakeResponsesClient.new(events: [])

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    response =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "echo", description: "Echo", parameters: { type: "object" } }],
        stream: false,
      )

    assert_equal :tool_use, response.stop_reason
    assert response.has_tool_calls?
    assert_equal 1, response.tool_calls.size
    assert_equal "call_1", response.tool_calls.first.id
    assert_equal "echo", response.tool_calls.first.name
    assert_equal({ "text" => "hello" }, response.tool_calls.first.arguments)
  end

  test "non-streaming responses maps max_tokens to max_output_tokens" do
    captured = []
    client =
      Class.new do
        define_method(:initialize) { |calls| @calls = calls }

        define_method(:responses) do |**kwargs|
          @calls << kwargs
          OpenStruct.new(
            output_text: "ok",
            output_items: [],
            usage: { "input_tokens" => 1, "output_tokens" => 1 },
            response: OpenStruct.new(body: { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }),
          )
        end
      end.new(captured)

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    provider.chat(
      messages: [AgentCore::Message.new(role: :user, content: "hi")],
      model: "m",
      tools: nil,
      stream: false,
      max_tokens: 123,
    )

    request = captured.first
    assert_equal 123, request[:max_output_tokens]
    assert_nil request[:max_tokens]
  end

  test "non-streaming responses reports incomplete max_output_tokens as max_tokens stop reason" do
    client =
      Class.new do
        def responses(**_kwargs)
          OpenStruct.new(
            output_text: "Partial",
            output_items: [],
            usage: { "input_tokens" => 1, "output_tokens" => 2 },
            response: OpenStruct.new(
              body: {
                "status" => "incomplete",
                "incomplete_details" => { "reason" => "max_output_tokens" },
                "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
              },
            ),
          )
        end
      end.new

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    response =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: false,
      )

    assert_equal :max_tokens, response.stop_reason
  end

  test "non-streaming responses falls back to item id when call_id is absent" do
    client =
      Class.new do
        def responses(**_kwargs)
          OpenStruct.new(
            output_text: "",
            usage: { "input_tokens" => 1, "output_tokens" => 2 },
            output_items: [
              {
                "type" => "function_call",
                "id" => "item_1",
                "name" => "echo",
                "arguments" => "{\"text\":\"hello\"}",
              },
            ],
            response: OpenStruct.new(body: { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } }),
          )
        end
      end.new

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    response =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "echo", description: "Echo", parameters: { type: "object" } }],
        stream: false,
      )

    assert_equal "item_1", response.tool_calls.first.id
  end

  test "responses provider rejects clients that do not implement the responses interface" do
    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: Object.new,
        wire_api: :responses,
      )

    error =
      assert_raises(AgentCore::ConfigurationError) do
        provider.chat(
          messages: [AgentCore::Message.new(role: :user, content: "hi")],
          model: "m",
          tools: nil,
          stream: false,
        )
      end

    assert_includes error.message, "responses interface"
  end

  test "non-streaming responses preserves configuration error as agentcore configuration error" do
    client =
      Class.new do
        def responses(**_kwargs)
          raise SimpleInference::ConfigurationError, "bad config"
        end
      end.new

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    error =
      assert_raises(AgentCore::ConfigurationError) do
        provider.chat(
          messages: [AgentCore::Message.new(role: :user, content: "hi")],
          model: "m",
          tools: nil,
          stream: false,
        )
      end

    assert_includes error.message, "bad config"
  end

  test "streaming responses supports tool calling events and message tool_calls" do
    client =
      FakeResponsesClient.new(
        events: [
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
          { "type" => "response.function_call_arguments.delta", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 2, "delta" => "{\"text\":\"he" },
          { "type" => "response.function_call_arguments.delta", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 3, "delta" => "llo\"}" },
          { "type" => "response.function_call_arguments.done", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 4, "name" => "echo", "arguments" => "{\"text\":\"hello\"}" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    enum =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "echo", description: "Echo", parameters: { type: "object" } }],
        stream: true,
      )

    events = enum.to_a

    tool_starts = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallStart) }
    assert_equal 1, tool_starts.size
    assert_equal "call_1", tool_starts.first.id
    assert_equal "echo", tool_starts.first.name

    tool_deltas = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallDelta) }
    assert_equal 2, tool_deltas.size
    assert_equal "{\"text\":\"he", tool_deltas.first.arguments_delta

    tool_ends = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallEnd) }
    assert_equal 1, tool_ends.size
    assert_equal "call_1", tool_ends.first.id
    assert_equal "echo", tool_ends.first.name
    assert_equal({ "text" => "hello" }, tool_ends.first.arguments)

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    assert complete.message.has_tool_calls?
    assert_equal 1, complete.message.tool_calls.size
    assert_equal "call_1", complete.message.tool_calls.first.id
    assert_equal "echo", complete.message.tool_calls.first.name
    assert_equal({ "text" => "hello" }, complete.message.tool_calls.first.arguments)

    done = events.find { |e| e.is_a?(AgentCore::StreamEvent::Done) }
    assert done
    assert_equal :tool_use, done.stop_reason
    assert_equal 1, done.usage.input_tokens
    assert_equal 2, done.usage.output_tokens

    assert_equal 1, client.calls.size
    sent_tools = client.calls.first[:tools] || client.calls.first["tools"]
    assert sent_tools.is_a?(Array)
    assert_equal "function", sent_tools.first["type"]
    assert_equal "echo", sent_tools.first["name"]
    assert_equal "object", sent_tools.first.dig("parameters", "type")
  end

  test "streaming responses preserves tool call order from output indexes" do
    client =
      FakeResponsesClient.new(
        events: [
          {
            "type" => "response.output_item.added",
            "output_index" => 1,
            "sequence_number" => 1,
            "item" => {
              "type" => "function_call",
              "id" => "item_a",
              "call_id" => "call_b",
              "name" => "second_tool",
              "arguments" => "",
            },
          },
          {
            "type" => "response.output_item.added",
            "output_index" => 0,
            "sequence_number" => 2,
            "item" => {
              "type" => "function_call",
              "id" => "item_z",
              "call_id" => "call_a",
              "name" => "first_tool",
              "arguments" => "",
            },
          },
          { "type" => "response.function_call_arguments.done", "item_id" => "item_a", "output_index" => 1, "sequence_number" => 3, "name" => "second_tool", "arguments" => "{\"value\":2}" },
          { "type" => "response.function_call_arguments.done", "item_id" => "item_z", "output_index" => 0, "sequence_number" => 4, "name" => "first_tool", "arguments" => "{\"value\":1}" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "first_tool", description: "First", parameters: { type: "object" } }, { name: "second_tool", description: "Second", parameters: { type: "object" } }],
        stream: true,
      ).to_a

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    names = complete.message.tool_calls.map(&:name)
    assert_equal ["first_tool", "second_tool"], names

    tool_ends = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallEnd) }
    assert_equal ["first_tool", "second_tool"], tool_ends.map(&:name)
  end

  test "streaming responses falls back to item id when call_id is absent" do
    client =
      FakeResponsesClient.new(
        events: [
          {
            "type" => "response.output_item.added",
            "output_index" => 0,
            "sequence_number" => 1,
            "item" => {
              "type" => "function_call",
              "id" => "item_1",
              "name" => "echo",
              "arguments" => "",
            },
          },
          { "type" => "response.function_call_arguments.done", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 2, "name" => "echo", "arguments" => "{\"text\":\"hello\"}" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "echo", description: "Echo", parameters: { type: "object" } }],
        stream: true,
      ).to_a

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    assert_equal "item_1", complete.message.tool_calls.first.id
  end

  test "streaming responses preserves call_id when added event is partial and name arrives later" do
    client =
      FakeResponsesClient.new(
        events: [
          {
            "type" => "response.output_item.added",
            "output_index" => 0,
            "sequence_number" => 1,
            "item" => {
              "type" => "function_call",
              "id" => "item_1",
              "call_id" => "call_1",
              "name" => "",
              "arguments" => "",
            },
          },
          { "type" => "response.function_call_arguments.delta", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 2, "delta" => "{\"text\":\"hello\"}" },
          { "type" => "response.function_call_arguments.done", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 3, "name" => "echo", "arguments" => "{\"text\":\"hello\"}" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "echo", description: "Echo", parameters: { type: "object" } }],
        stream: true,
      ).to_a

    tool_starts = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallStart) }
    assert_equal 1, tool_starts.size
    assert_equal "call_1", tool_starts.first.id
    assert_equal "echo", tool_starts.first.name

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    assert_equal "call_1", complete.message.tool_calls.first.id
    assert_equal "echo", complete.message.tool_calls.first.name
  end

  test "streaming responses upgrades buffered live tool-call events to final call_id when added arrives later" do
    client =
      FakeResponsesClient.new(
        events: [
          { "type" => "response.function_call_arguments.delta", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 1, "delta" => "{\"text\":\"he" },
          {
            "type" => "response.output_item.added",
            "output_index" => 0,
            "sequence_number" => 2,
            "item" => {
              "type" => "function_call",
              "id" => "item_1",
              "call_id" => "call_1",
              "name" => "echo",
              "arguments" => "",
            },
          },
          { "type" => "response.function_call_arguments.delta", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 3, "delta" => "llo\"}" },
          { "type" => "response.function_call_arguments.done", "item_id" => "item_1", "output_index" => 0, "sequence_number" => 4, "name" => "echo", "arguments" => "{\"text\":\"hello\"}" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "echo", description: "Echo", parameters: { type: "object" } }],
        stream: true,
      ).to_a

    tool_starts = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallStart) }
    assert_equal ["call_1"], tool_starts.map(&:id)

    tool_deltas = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallDelta) }
    assert_equal ["call_1", "call_1"], tool_deltas.map(&:id)
    assert_equal "{\"text\":\"he", tool_deltas.first.arguments_delta
    assert_equal "llo\"}", tool_deltas.second.arguments_delta

    tool_ends = events.select { |e| e.is_a?(AgentCore::StreamEvent::ToolCallEnd) }
    assert_equal ["call_1"], tool_ends.map(&:id)

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    assert_equal "call_1", complete.message.tool_calls.first.id
  end

  test "streaming responses falls back to non-sse json success response body" do
    client =
      Class.new do
        def responses_stream(**_kwargs)
          OpenStruct.new(
            body: {
              "output" => [
                {
                  "type" => "message",
                  "content" => [{ "type" => "output_text", "text" => "fallback ok" }],
                },
              ],
              "usage" => { "input_tokens" => 5, "output_tokens" => 6 },
            },
          )
        end
      end.new

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    assert_equal "fallback ok", complete.message.text

    done = events.find { |e| e.is_a?(AgentCore::StreamEvent::Done) }
    assert done
    assert_equal 5, done.usage.input_tokens
    assert_equal 6, done.usage.output_tokens
  end

  test "streaming responses falls back to headerless json success response body" do
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 200,
            headers: {},
            body: JSON.generate(
              {
                "output" => [
                  {
                    "type" => "message",
                    "content" => [{ "type" => "output_text", "text" => "headerless ok" }],
                  },
                ],
                "usage" => { "input_tokens" => 7, "output_tokens" => 8 },
              },
            ),
          }
        end
      end.new

    client =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    assert_equal "headerless ok", complete.message.text

    done = events.find { |e| e.is_a?(AgentCore::StreamEvent::Done) }
    assert done
    assert_equal 7, done.usage.input_tokens
    assert_equal 8, done.usage.output_tokens
  end

  test "streaming responses enriches streamed tool calls with final response body call_id" do
    client =
      Class.new do
        def responses_stream(**_kwargs)
          yield(
            {
              "type" => "response.function_call_arguments.done",
              "item_id" => "item_1",
              "output_index" => 0,
              "sequence_number" => 1,
              "name" => "echo",
              "arguments" => "{\"text\":\"hello\"}",
            },
          )

          OpenStruct.new(
            body: {
              "output" => [
                {
                  "type" => "function_call",
                  "id" => "item_1",
                  "call_id" => "call_1",
                  "name" => "echo",
                  "arguments" => "{\"text\":\"hello\"}",
                },
              ],
              "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
            },
          )
        end
      end.new

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
      )

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: [{ name: "echo", description: "Echo", parameters: { type: "object" } }],
        stream: true,
      ).to_a

    complete = events.find { |e| e.is_a?(AgentCore::StreamEvent::MessageComplete) }
    assert complete
    assert complete.message.has_tool_calls?
    assert_equal "call_1", complete.message.tool_calls.first.id
  end

  test "transport auto records fallback metadata (no silent behavior)" do
    client =
      FakeResponsesClient.new(
        events: [
          { "type" => "response.output_text.delta", "delta" => "Hi" },
          { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
        ],
      )

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        client: client,
        wire_api: :responses,
        transport: :auto,
      )

    enum =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      )

    _ = enum.to_a
    md = provider.last_call_metadata
    assert_equal "auto", md.dig("llm_transport", "configured")
    assert_equal "http_sse", md.dig("llm_transport", "effective")
    assert_equal "websocket_not_supported", md.dig("llm_transport", "fallback")
  end

  test "streaming responses preserves http error as provider error event" do
    response =
      SimpleInference::Response.new(
        status: 400,
        headers: { "content-type" => "application/json" },
        body: { "error" => { "message" => "bad request" } },
        raw_body: "{\"error\":{\"message\":\"bad request\"}}",
      )
    client = RaisingResponsesClient.new(error: SimpleInference::HTTPError.new("bad request", response: response))

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    error_event = events.find { |e| e.is_a?(AgentCore::StreamEvent::ErrorEvent) }
    refute_nil error_event
    assert_instance_of AgentCore::ProviderError, error_event.error
    assert_equal 400, error_event.error.status
    assert_equal false, error_event.recoverable?
  end

  test "streaming responses preserves configuration error as validation error event" do
    client = RaisingResponsesClient.new(error: SimpleInference::ConfigurationError.new("bad config"))

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    error_event = events.find { |e| e.is_a?(AgentCore::StreamEvent::ErrorEvent) }
    refute_nil error_event
    assert_instance_of AgentCore::ConfigurationError, error_event.error
    assert_equal false, error_event.recoverable?
  end

  test "streaming responses marks timeout error as recoverable bootstrap failure" do
    client = RaisingResponsesClient.new(error: SimpleInference::TimeoutError.new("timed out"))

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    error_event = events.find { |e| e.is_a?(AgentCore::StreamEvent::ErrorEvent) }
    refute_nil error_event
    assert_instance_of SimpleInference::TimeoutError, error_event.error
    assert_equal true, error_event.recoverable?
  end

  test "streaming responses marks connection error as recoverable bootstrap failure" do
    client = RaisingResponsesClient.new(error: SimpleInference::ConnectionError.new("connection lost"))

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    error_event = events.find { |e| e.is_a?(AgentCore::StreamEvent::ErrorEvent) }
    refute_nil error_event
    assert_instance_of SimpleInference::ConnectionError, error_event.error
    assert_equal true, error_event.recoverable?
  end

  test "streaming responses marks decode error as recoverable protocol failure" do
    client = RaisingResponsesClient.new(error: SimpleInference::DecodeError.new("bad sse"))

    provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client, wire_api: :responses)

    events =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "m",
        tools: nil,
        stream: true,
      ).to_a

    error_event = events.find { |e| e.is_a?(AgentCore::StreamEvent::ErrorEvent) }
    refute_nil error_event
    assert_instance_of SimpleInference::DecodeError, error_event.error
    assert_equal true, error_event.recoverable?
  end
end
