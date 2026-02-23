# frozen_string_literal: true

require "test_helper"

class AgentCoreDirectivesRunnerTest < ActiveSupport::TestCase
  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(responses:)
      @responses = Array(responses)
      @calls = []
    end

    attr_reader :calls

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @calls << { messages: messages, model: model, tools: tools, stream: stream, options: options }
      resp = @responses.shift
      raise "unexpected provider.chat call (no remaining responses)" unless resp

      resp
    end
  end

  test "Runner repairs invalid JSON and returns normalized directives envelope" do
    registry =
      AgentCore::Directives::Registry.new(
        definitions: [
          {
            type: "ui.toast",
            description: "Show a toast",
            aliases: ["toast"],
          },
        ],
      )

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "not json"),
            stop_reason: :end_turn,
          ),
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "{\"assistant_text\":\"hi\",\"directives\":[{\"type\":\"toast\",\"payload\":{\"message\":\"ok\"}}]}",
              ),
            stop_reason: :end_turn,
          ),
        ],
      )

    runner =
      AgentCore::Directives::Runner.new(
        provider: provider,
        model: "test-model",
        llm_options_defaults: { temperature: 0.2 },
        directives_config: { repair_retry_count: 1, modes: [:json_schema] },
      )

    result =
      runner.run(
        history: [AgentCore::Message.new(role: :user, content: "hello")],
        structured_output_options: { registry: registry },
      )

    assert result[:ok]
    assert_equal :json_schema, result[:mode]
    assert_equal "hi", result[:assistant_text]
    assert_equal 1, result.fetch(:directives).length
    assert_equal "ui.toast", result.fetch(:directives).first.fetch("type")
    assert_equal({ "message" => "ok" }, result.fetch(:directives).first.fetch("payload"))

    assert_equal 2, provider.calls.length
    repair_system = provider.calls.fetch(1).fetch(:messages).first.text
    assert_includes repair_system, "Your previous response was invalid"
  end

  test "Runner treats tool_calls in directives mode as invalid and recovers on repair" do
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "oops",
                tool_calls: [AgentCore::ToolCall.new(id: "tc_1", name: "echo", arguments: {})],
              ),
            stop_reason: :tool_use,
          ),
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "{\"assistant_text\":\"ok\",\"directives\":[]}",
              ),
            stop_reason: :end_turn,
          ),
        ],
      )

    runner =
      AgentCore::Directives::Runner.new(
        provider: provider,
        model: "test-model",
        llm_options_defaults: {},
        directives_config: { repair_retry_count: 1, modes: [:json_schema] },
      )

    result =
      runner.run(
        history: [AgentCore::Message.new(role: :user, content: "hello")],
        structured_output_options: { allowed_types: [] },
      )

    assert result[:ok]
    assert_equal "ok", result[:assistant_text]
    assert_equal 2, provider.calls.length
  end

  test "Runner skips unsupported structured modes and falls back to prompt_only" do
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message:
              AgentCore::Message.new(
                role: :assistant,
                content: "{\"assistant_text\":\"ok\",\"directives\":[]}",
              ),
            stop_reason: :end_turn,
          ),
        ],
      )

    runner =
      AgentCore::Directives::Runner.new(
        provider: provider,
        model: "test-model",
        llm_options_defaults: {},
        directives_config: { repair_retry_count: 0 },
        capabilities: {
          supports_response_format_json_schema: false,
          supports_response_format_json_object: false,
        },
      )

    result =
      runner.run(
        history: [AgentCore::Message.new(role: :user, content: "hello")],
        structured_output_options: { allowed_types: [] },
      )

    assert result[:ok]
    assert_equal :prompt_only, result[:mode]
    assert_equal 3, result.fetch(:attempts).length

    skipped = result.fetch(:attempts).take(2)
    assert skipped.all? { |a| a[:skipped] == true }
  end
end
