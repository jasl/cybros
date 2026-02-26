require "test_helper"

class MockLlmTest < ActionDispatch::IntegrationTest
  def parse_sse_events(body)
    events = []

    body.to_s.split(/\r?\n\r?\n/).each do |block|
      block.to_s.split(/\r?\n/).each do |line|
        next unless line.start_with?("data:")

        data = line.delete_prefix("data:").lstrip
        next if data.strip.empty?
        break events if data.strip == "[DONE]"

        events << JSON.parse(data)
      end
    end

    events
  end

  test "models endpoint returns a mock model" do
    get "/mock_llm/v1/models"

    assert_response :success

    body = JSON.parse(response.body)
    assert_equal "list", body.fetch("object")
    assert_equal "mock-model", body.fetch("data").first.fetch("id")
  end

  test "non-streaming chat completions returns OpenAI-compatible JSON" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: "Hello" }],
           stream: false,
         },
         as: :json

    assert_response :success

    body = JSON.parse(response.body)
    assert_equal "chat.completion", body.fetch("object")
    assert_equal "mock-model", body.fetch("model")
    assert_equal "assistant", body.dig("choices", 0, "message", "role")
    assert_equal "Mock: Hello", body.dig("choices", 0, "message", "content")
    assert body.fetch("usage").is_a?(Hash)
  end

  test "chat completions errors when model is missing" do
    post "/mock_llm/v1/chat/completions",
         params: {
           messages: [{ role: "user", content: "Hi" }],
         },
         as: :json

    assert_response :bad_request

    body = JSON.parse(response.body)
    assert_equal "invalid_request_error", body.dig("error", "type")
    assert_equal "model is required", body.dig("error", "message")
  end

  test "chat completions errors when messages is empty" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [],
         },
         as: :json

    assert_response :bad_request

    body = JSON.parse(response.body)
    assert_equal "invalid_request_error", body.dig("error", "type")
    assert_equal "messages must be a non-empty array", body.dig("error", "message")
  end

  test "chat completions errors on invalid JSON body" do
    post "/mock_llm/v1/chat/completions",
         params: "{",
         headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request

    body = JSON.parse(response.body)
    assert_equal "invalid_request_error", body.dig("error", "type")
    assert_equal "invalid JSON body", body.dig("error", "message")
  end

  test "streaming chat completions returns SSE chunks + DONE" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: "Hello" }],
           stream: true,
           stream_options: { include_usage: true },
         },
         as: :json

    assert_response :success
    assert_includes response.headers.fetch("content-type"), "text/event-stream"
    assert_includes response.body, "data:"
    assert_includes response.body, "[DONE]"

    events = parse_sse_events(response.body)
    assert events.any?

    deltas = events.map { |e| e.dig("choices", 0, "delta", "content") }.compact.join
    assert_equal "Mock: Hello", deltas

    last = events.last
    assert_equal "stop", last.dig("choices", 0, "finish_reason")
    assert last.fetch("usage").is_a?(Hash)
  end
end
