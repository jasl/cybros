# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Tools::ToolCallRepairLoopSchemaTruncationTest < Minitest::Test
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

  def test_schema_is_truncated_to_max_bytes_in_prompt
    huge_enum = 1_000.times.map { |i| "value_#{i}" }

    visible_tools = [
      {
        name: "choose",
        description: "Choose",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            "choice" => { type: "string", enum: huge_enum },
          },
          required: ["choice"],
        },
      },
    ]

    tool_calls = [
      AgentCore::ToolCall.new(
        id: "tc_1",
        name: "choose",
        arguments: {},
        arguments_parse_error: :invalid_json,
        arguments_raw: "{bad",
      ),
    ]

    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"arguments\":{\"choice\":\"value_1\"}}]}"),
            stop_reason: :end_turn,
          ),
        ]
      )

    result =
      AgentCore::Resources::Tools::ToolCallRepairLoop.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: [],
        tool_calls: tool_calls,
        visible_tools: visible_tools,
        max_output_tokens: 300,
        max_attempts: 1,
        validate_schema: false,
        schema_max_depth: 2,
        max_schema_bytes: 500,
        options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        run_id: "rid",
      )

    assert_equal 1, provider.calls.length
    user_payload = JSON.parse(provider.calls.first.fetch(:messages).last.text)
    schema = user_payload.fetch("candidates").first.fetch("schema")
    assert_operator JSON.generate(schema).bytesize, :<=, 500

    repair = result.fetch(:metadata).dig("tool_loop", "repair")
    assert_equal 500, repair.fetch("max_schema_bytes")
    assert_equal 1, repair.fetch("schema_truncated_candidates")
  end
end
