require "test_helper"

class AgentCore::Resources::Tools::ToolCallRepairLoopTest < Minitest::Test
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

  class CaptureInstrumenter < AgentCore::Observability::Instrumenter
    attr_reader :events

    def initialize
      @events = []
    end

    def _publish(name, payload)
      @events << { name: name, payload: payload }
    end
  end

  def test_repairs_invalid_json_arguments
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"arguments\":{\"text\":\"hi\"}}]}"),
            stop_reason: :end_turn,
          ),
        ]
      )

    tool_calls = [
      AgentCore::ToolCall.new(
        id: "tc_1",
        name: "echo",
        arguments: {},
        arguments_parse_error: :invalid_json,
        arguments_raw: "{bad",
      ),
    ]

    visible_tools = [
      {
        name: "echo",
        description: "Echo",
        parameters: { type: "object", properties: { "text" => { type: "string" } } },
      },
    ]

    inst = CaptureInstrumenter.new

    result =
      AgentCore::Resources::Tools::ToolCallRepairLoop.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: [],
        tool_calls: tool_calls,
        visible_tools: visible_tools,
        max_output_tokens: 300,
        max_attempts: 1,
        options: {},
        instrumenter: inst,
        run_id: "rid",
      )

    repaired = result.fetch(:tool_calls).first
    assert_nil repaired.arguments_parse_error
    assert_equal({ "text" => "hi" }, repaired.arguments)

    metadata = result.fetch(:metadata)
    repair = metadata.dig("tool_loop", "repair")
    assert_equal 1, repair.fetch("repaired")
    assert_equal 1, repair.fetch("candidates")

    assert_equal 1, provider.calls.length
    assert_nil provider.calls.first.fetch(:tools)

    repair_events = inst.events.select { |e| e.fetch(:name) == "agent_core.tool.repair" }
    assert_equal 1, repair_events.length
  end

  def test_retries_when_model_output_is_not_json
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(message: AgentCore::Message.new(role: :assistant, content: "nope"), stop_reason: :end_turn),
          AgentCore::Resources::Provider::Response.new(message: AgentCore::Message.new(role: :assistant, content: "still nope"), stop_reason: :end_turn),
        ]
      )

    tool_calls = [
      AgentCore::ToolCall.new(
        id: "tc_1",
        name: "echo",
        arguments: {},
        arguments_parse_error: :invalid_json,
        arguments_raw: "{bad",
      ),
    ]

    visible_tools = [
      { name: "echo", description: "Echo", parameters: { type: "object", properties: {} } },
    ]

    result =
      AgentCore::Resources::Tools::ToolCallRepairLoop.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: [],
        tool_calls: tool_calls,
        visible_tools: visible_tools,
        max_output_tokens: 300,
        max_attempts: 2,
        options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        run_id: "rid",
      )

    unchanged = result.fetch(:tool_calls).first
    assert_equal :invalid_json, unchanged.arguments_parse_error

    repair = result.fetch(:metadata).dig("tool_loop", "repair")
    assert_equal 2, repair.fetch("attempts")
    assert_equal 1, repair.fetch("candidates")
    assert_equal 0, repair.fetch("repaired")
    assert_equal 1, repair.fetch("failed")
  end

  def test_repairs_schema_invalid_arguments
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"arguments\":{\"text\":\"hi\"}}]}"),
            stop_reason: :end_turn,
          ),
        ]
      )

    tool_calls = [
      AgentCore::ToolCall.new(
        id: "tc_1",
        name: "echo",
        arguments: {},
      ),
    ]

    visible_tools = [
      {
        name: "echo",
        description: "Echo",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: { "text" => { type: "string" } },
          required: ["text"],
        },
      },
    ]

    result =
      AgentCore::Resources::Tools::ToolCallRepairLoop.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: [],
        tool_calls: tool_calls,
        visible_tools: visible_tools,
        max_output_tokens: 300,
        max_attempts: 1,
        validate_schema: true,
        schema_max_depth: 2,
        options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        run_id: "rid",
      )

    repaired = result.fetch(:tool_calls).first
    assert_nil repaired.arguments_parse_error
    assert_equal({ "text" => "hi" }, repaired.arguments)

    repair = result.fetch(:metadata).dig("tool_loop", "repair")
    assert_equal 1, repair.fetch("candidates")
    assert_equal 1, repair.fetch("repaired")
  end

  def test_partial_repair_is_allowed
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"arguments\":{\"text\":\"hi\"}}]}"),
            stop_reason: :end_turn,
          ),
        ]
      )

    tool_calls = [
      AgentCore::ToolCall.new(id: "tc_1", name: "echo", arguments: {}, arguments_parse_error: :invalid_json, arguments_raw: "{bad"),
      AgentCore::ToolCall.new(id: "tc_2", name: "math.add", arguments: {}, arguments_parse_error: :invalid_json, arguments_raw: "{bad"),
    ]

    visible_tools = [
      { name: "echo", description: "Echo", parameters: { type: "object", properties: { "text" => { type: "string" } } } },
      { name: "math_add", description: "Add", parameters: { type: "object", properties: { "a" => { type: "number" }, "b" => { type: "number" } } } },
    ]

      result =
        AgentCore::Resources::Tools::ToolCallRepairLoop.call(
          provider: provider,
          requested_model: "primary",
          fallback_models: [],
          tool_calls: tool_calls,
          visible_tools: visible_tools,
          max_output_tokens: 300,
          max_attempts: 1,
          tool_name_aliases: { "math.add" => "math_add" },
          options: {},
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
          run_id: "rid",
        )

    repaired_calls = result.fetch(:tool_calls)
    assert_nil repaired_calls.first.arguments_parse_error
    assert_equal :invalid_json, repaired_calls.second.arguments_parse_error

    repair = result.fetch(:metadata).dig("tool_loop", "repair")
    assert_equal 2, repair.fetch("candidates")
    assert_equal 1, repair.fetch("repaired")
    assert_equal 1, repair.fetch("failed")
  end
end
