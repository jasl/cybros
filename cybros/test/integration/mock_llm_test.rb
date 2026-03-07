require "test_helper"

class MockLlmTest < ActionDispatch::IntegrationTest
  def with_modified_env(key, value)
    previous = ENV[key]
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end

    yield
  ensure
    if previous.nil?
      ENV.delete(key)
    else
      ENV[key] = previous
    end
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

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

  test "single digit prompt is recognized as a delayed shortcut" do
    controller = MockLLM::V1::ChatCompletionsController.new

    with_modified_env("MOCK_LLM_MAX_SLOW_SECONDS", "9") do
      assert_equal 3.0, controller.send(:numeric_prompt_delay_seconds, "3")
      assert_equal 9.0, controller.send(:numeric_prompt_delay_seconds, "9")
      assert_nil controller.send(:numeric_prompt_delay_seconds, "0")
      assert_nil controller.send(:numeric_prompt_delay_seconds, "10")
      assert_nil controller.send(:numeric_prompt_delay_seconds, "3 seconds")
    end
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
    assert_match(/\AMock: Hello \[[0-9a-f]{6}\]\z/, body.dig("choices", 0, "message", "content"))
    assert body.fetch("usage").is_a?(Hash)
  end

  test "plain-text mock completions append a short random suffix" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: "Hello" }],
           stream: false,
         },
         as: :json

    assert_response :success
    first_content = JSON.parse(response.body).dig("choices", 0, "message", "content")

    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: "Hello" }],
           stream: false,
         },
         as: :json

    assert_response :success
    second_content = JSON.parse(response.body).dig("choices", 0, "message", "content")

    assert_match(/\AMock: Hello \[[0-9a-f]{6}\]\z/, first_content)
    assert_match(/\AMock: Hello \[[0-9a-f]{6}\]\z/, second_content)
    refute_equal first_content, second_content
  end

  test "single digit prompt returns delayed random content for non-streaming completions" do
    elapsed = nil

    with_modified_env("MOCK_LLM_MAX_SLOW_SECONDS", "0.01") do
      started_at = monotonic_time

      post "/mock_llm/v1/chat/completions",
           params: {
             model: "mock-model",
             messages: [{ role: "user", content: "3" }],
             stream: false,
           },
           as: :json

      elapsed = monotonic_time - started_at
    end

    assert_response :success

    body = JSON.parse(response.body)
    content = body.dig("choices", 0, "message", "content").to_s

    assert_operator elapsed, :>=, 0.01
    assert_match(/\AMock delayed 3s: [a-z0-9]{24}\z/, content)
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
    assert_match(/\AMock: Hello \[[0-9a-f]{6}\]\z/, deltas)

    last = events.last
    assert_equal "stop", last.dig("choices", 0, "finish_reason")
    assert last.fetch("usage").is_a?(Hash)
  end

  test "single digit prompt returns delayed random content for streaming completions" do
    elapsed = nil

    with_modified_env("MOCK_LLM_MAX_SLOW_SECONDS", "0.01") do
      started_at = monotonic_time

      post "/mock_llm/v1/chat/completions",
           params: {
             model: "mock-model",
             messages: [{ role: "user", content: "4" }],
             stream: true,
             stream_options: { include_usage: true },
           },
           as: :json

      elapsed = monotonic_time - started_at
    end

    assert_response :success
    assert_includes response.headers.fetch("content-type"), "text/event-stream"
    assert_includes response.body, "[DONE]"

    events = parse_sse_events(response.body)
    deltas = events.map { |e| e.dig("choices", 0, "delta", "content") }.compact.join

    assert_operator elapsed, :>=, 0.01
    assert_match(/\AMock delayed 4s: [a-z0-9]{24}\z/, deltas)
  end

  test "markdown mode returns deterministic markdown content" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: "!md hi" }],
           stream: false,
         },
         as: :json

    assert_response :success

    body = JSON.parse(response.body)
    content = body.dig("choices", 0, "message", "content").to_s
    assert_includes content, "# Mock Markdown"
    assert_includes content, "**Prompt:**"
  end

  test "mock directive can force OpenAI-compatible errors" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: '!mock error=429 message="rate limited" -- hello' }],
           stream: false,
         },
         as: :json

    assert_response 429

    body = JSON.parse(response.body)
    assert_equal "rate_limit_error", body.dig("error", "type")
    assert_equal "rate limited", body.dig("error", "message")
  end

  test "mock directive errors return JSON even when stream=true" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: "!mock error=401 -- hello" }],
           stream: true,
         },
         as: :json

    assert_response 401
    assert_includes response.headers.fetch("content-type"), "application/json"

    body = JSON.parse(response.body)
    assert_equal "authentication_error", body.dig("error", "type")
    assert_equal "mock error", body.dig("error", "message")
  end

  test "mock directive strips controls from streaming output" do
    post "/mock_llm/v1/chat/completions",
         params: {
           model: "mock-model",
           messages: [{ role: "user", content: "!mock slow=0.001 -- Hello" }],
           stream: true,
           stream_options: { include_usage: true },
         },
         as: :json

    assert_response :success
    assert_includes response.headers.fetch("content-type"), "text/event-stream"
    assert_includes response.body, "[DONE]"

    events = parse_sse_events(response.body)
    deltas = events.map { |e| e.dig("choices", 0, "delta", "content") }.compact.join
    assert_match(/\AMock: Hello \[[0-9a-f]{6}\]\z/, deltas)
  end
end
