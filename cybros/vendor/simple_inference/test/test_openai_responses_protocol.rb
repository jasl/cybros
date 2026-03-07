# frozen_string_literal: true

require "json"
require "test_helper"

class TestOpenAIResponsesProtocol < Minitest::Test
  def test_responses_create_posts_to_configured_path
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
                "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com/v1",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    protocol.responses_create(model: "m", input: "Hello")

    assert_equal :post, adapter.last_request[:method]
    assert_equal "http://example.com/v1/responses", adapter.last_request[:url]
    body = JSON.parse(adapter.last_request[:body])
    assert_equal "m", body.fetch("model")
    assert_equal "Hello", body.fetch("input")
  end

  def test_responses_raises_validation_error_when_model_missing
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        raise "adapter should not be reached"
      end
    end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com/v1",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses(model: nil, input: "Hello")
      end

    assert_includes error.message, "model is required"
  end

  def test_responses_stream_yields_parsed_sse_events
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"Hel"}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"lo"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          # Chunked to exercise buffering.
          [sse[0, 11], sse[11, 13], sse[24..]].compact.each { |chunk| yield chunk }

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    events = protocol.responses_stream(model: "m", input: "Hello").to_a

    assert_equal(
      [
        { "type" => "response.output_text.delta", "delta" => "Hel" },
        { "type" => "response.output_text.delta", "delta" => "lo" },
        { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
      ],
      events
    )
  end

  def test_responses_stream_parses_sse_body_when_content_type_is_missing
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: response.created\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"Hel"}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"lo"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          { status: 200, headers: {}, body: sse }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    events = protocol.responses_stream(model: "m", input: "Hello").to_a

    assert_equal(
      [
        { "type" => "response.output_text.delta", "delta" => "Hel" },
        { "type" => "response.output_text.delta", "delta" => "lo" },
        { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
      ],
      events,
    )
  end

  def test_responses_high_level_accumulates_text_and_extracts_usage
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"a"}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"b"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":4}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    deltas = []
    result =
      protocol.responses(model: "m", input: "Hello", stream: true) do |delta|
        deltas << delta
      end

    assert_equal ["a", "b"], deltas
    assert_equal "ab", result.output_text
    assert_equal({ "input_tokens" => 3, "output_tokens" => 4 }, result.usage)
  end

  def test_responses_high_level_streaming_falls_back_to_non_sse_json_success_response
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "fallback ok" }] },
                ],
                "usage" => { "input_tokens" => 5, "output_tokens" => 6 },
              },
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    deltas = []
    result =
      protocol.responses(model: "m", input: "Hello", stream: true) do |delta|
        deltas << delta
      end

    assert_equal [], deltas
    assert_equal "fallback ok", result.output_text
    assert_equal({ "input_tokens" => 5, "output_tokens" => 6 }, result.usage)
  end

  def test_responses_high_level_streaming_falls_back_to_headerless_json_success_response
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 200,
            headers: {},
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "headerless ok" }] },
                ],
                "usage" => { "input_tokens" => 7, "output_tokens" => 8 },
              },
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    deltas = []
    result =
      protocol.responses(model: "m", input: "Hello", stream: true) do |delta|
        deltas << delta
      end

    assert_equal [], deltas
    assert_equal "headerless ok", result.output_text
    assert_equal({ "input_tokens" => 7, "output_tokens" => 8 }, result.usage)
  end

  def test_responses_high_level_extracts_function_calls_from_body
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_req)
          body = {
            "output" => [
              {
                "type" => "function_call",
                "id" => "item_1",
                "call_id" => "call_1",
                "name" => "echo",
                "arguments" => "{\"text\":\"hello\"}",
              },
              {
                "type" => "message",
                "role" => "assistant",
                "content" => [{ "type" => "output_text", "text" => "ok" }],
              },
            ],
            "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
          }

          { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(body) }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: false)

    items = result.output_items
    assert items.is_a?(Array)
    fc = items.find { |i| i.is_a?(Hash) && i["type"] == "function_call" }
    refute_nil fc
    assert_equal "call_1", fc["call_id"]
    assert_equal "echo", fc["name"]
    assert_equal "{\"text\":\"hello\"}", fc["arguments"]
  end

  def test_responses_high_level_streaming_reconstructs_function_call_output_items
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":""}}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"{\\"text\\":\\"he"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"llo\\"}"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.done","item_id":"item_1","output_index":0,"name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_equal({ "input_tokens" => 1, "output_tokens" => 2 }, result.usage)
    assert_equal 1, result.output_items.length
    function_call = result.output_items.first
    assert_equal "function_call", function_call["type"]
    assert_equal "call_1", function_call["call_id"]
    assert_equal "echo", function_call["name"]
    assert_equal "{\"text\":\"hello\"}", function_call["arguments"]
  end

  def test_responses_high_level_streaming_enriches_function_call_items_from_output_item_done
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.function_call_arguments.done","item_id":"item_1","output_index":0,"name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}\n\n)
          sse << %(data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_equal 1, result.output_items.length
    function_call = result.output_items.first
    assert_equal "function_call", function_call["type"]
    assert_equal "call_1", function_call["call_id"]
    assert_equal "echo", function_call["name"]
  end

  def test_responses_high_level_streaming_preserves_arguments_when_output_item_done_is_sparse
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"{\\"text\\":\\"he"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"llo\\"}"}\n\n)
          sse << %(data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":""}}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_equal 1, result.output_items.length
    function_call = result.output_items.first
    assert_equal "function_call", function_call["type"]
    assert_equal "call_1", function_call["call_id"]
    assert_equal "echo", function_call["name"]
    assert_equal "{\"text\":\"hello\"}", function_call["arguments"]
  end

  def test_responses_stream_raises_decode_error_for_malformed_sse_json
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          yield %(data: {"type":"response.output_text.delta","delta":"oops"\n\n)
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::DecodeError) do
      protocol.responses_stream(model: "m", input: "Hello").to_a
    end
  end

  def test_responses_stream_wraps_timeout_as_timeout_error
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          raise Timeout::Error, "timed out"
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::TimeoutError) do
      protocol.responses_stream(model: "m", input: "Hello").to_a
    end
  end

  def test_responses_stream_wraps_socket_error_as_connection_error
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          raise SocketError, "dns failed"
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::ConnectionError) do
      protocol.responses_stream(model: "m", input: "Hello").to_a
    end
  end

  def test_responses_stream_raises_http_error_for_non_2xx_json_response
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 400,
            headers: { "content-type" => "application/json" },
            body: JSON.generate({ "error" => { "message" => "bad request" } }),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    err =
      assert_raises(SimpleInference::HTTPError) do
        protocol.responses_stream(model: "m", input: "Hello").to_a
      end

    assert_equal 400, err.status
  end
end
