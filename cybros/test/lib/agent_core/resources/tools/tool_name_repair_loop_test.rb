require "test_helper"

class AgentCore::Resources::Tools::ToolNameRepairLoopTest < Minitest::Test
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

  def test_repairs_tool_not_found_name_to_visible_tool
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"name\":\"echo\"}]}"),
            stop_reason: :end_turn,
          ),
        ]
      )

    tool_calls = [AgentCore::ToolCall.new(id: "tc_1", name: "no_such_tool", arguments: { "text" => "hi" })]
    visible_tools = [{ name: "echo", description: "Echo", parameters: { type: "object", properties: {} } }]

    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(AgentCore::Resources::Tools::Tool.new(name: "echo", description: "Echo", parameters: { type: "object", properties: {} }) { |_args, **_kw| })

    inst = CaptureInstrumenter.new

    result =
      AgentCore::Resources::Tools::ToolNameRepairLoop.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: [],
        tool_calls: tool_calls,
        visible_tools: visible_tools,
        tools_registry: registry,
        max_attempts: 1,
        max_output_tokens: 200,
        max_candidates: 10,
        max_visible_tool_names: 200,
        tool_name_aliases: {},
        tool_name_normalize_fallback: false,
        options: {},
        instrumenter: inst,
        run_id: "rid",
      )

    assert_equal({ "tc_1" => "echo" }, result.fetch(:tool_name_repairs))

    meta = result.fetch(:metadata).dig("tool_loop", "tool_name_repair")
    assert_equal 1, meta.fetch("attempts")
    assert_equal 1, meta.fetch("candidates_total")
    assert_equal 1, meta.fetch("candidates_sent")
    assert_equal 1, meta.fetch("repaired")
    assert_equal 0, meta.fetch("failed")
    assert_equal 1, meta.fetch("visible_tools_total")

    assert_equal 1, provider.calls.length
    assert_nil provider.calls.first.fetch(:tools)

    events = inst.events.select { |e| e.fetch(:name) == "agent_core.tool.name_repair" }
    assert_equal 1, events.length
  end

  def test_retries_when_model_output_is_not_json
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(message: AgentCore::Message.new(role: :assistant, content: "nope"), stop_reason: :end_turn),
          AgentCore::Resources::Provider::Response.new(message: AgentCore::Message.new(role: :assistant, content: "still nope"), stop_reason: :end_turn),
        ]
      )

    tool_calls = [AgentCore::ToolCall.new(id: "tc_1", name: "no_such_tool", arguments: {})]
    visible_tools = [{ name: "echo", description: "Echo", parameters: { type: "object", properties: {} } }]

    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(AgentCore::Resources::Tools::Tool.new(name: "echo", description: "Echo", parameters: { type: "object", properties: {} }) { |_args, **_kw| })

    result =
      AgentCore::Resources::Tools::ToolNameRepairLoop.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: [],
        tool_calls: tool_calls,
        visible_tools: visible_tools,
        tools_registry: registry,
        max_attempts: 2,
        max_output_tokens: 200,
        max_candidates: 10,
        max_visible_tool_names: 200,
        tool_name_aliases: {},
        tool_name_normalize_fallback: false,
        options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        run_id: "rid",
      )

    assert_equal({}, result.fetch(:tool_name_repairs))

    meta = result.fetch(:metadata).dig("tool_loop", "tool_name_repair")
    assert_equal 2, meta.fetch("attempts")
    failures = meta.fetch("failures_sample")
    assert failures.any? { |h| h.fetch("reason").to_s.include?("json_parse_failed") }
  end

  def test_repair_name_must_be_in_visible_tools
    provider =
      StubProvider.new(
        responses: [
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "{\"repairs\":[{\"tool_call_id\":\"tc_1\",\"name\":\"not_visible\"}]}"),
            stop_reason: :end_turn,
          ),
        ]
      )

    tool_calls = [AgentCore::ToolCall.new(id: "tc_1", name: "no_such_tool", arguments: {})]
    visible_tools = [{ name: "echo", description: "Echo", parameters: { type: "object", properties: {} } }]

    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(AgentCore::Resources::Tools::Tool.new(name: "echo", description: "Echo", parameters: { type: "object", properties: {} }) { |_args, **_kw| })

    result =
      AgentCore::Resources::Tools::ToolNameRepairLoop.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: [],
        tool_calls: tool_calls,
        visible_tools: visible_tools,
        tools_registry: registry,
        max_attempts: 1,
        max_output_tokens: 200,
        max_candidates: 10,
        max_visible_tool_names: 200,
        tool_name_aliases: {},
        tool_name_normalize_fallback: false,
        options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        run_id: "rid",
      )

    assert_equal({}, result.fetch(:tool_name_repairs))

    meta = result.fetch(:metadata).dig("tool_loop", "tool_name_repair")
    assert_equal 1, meta.fetch("candidates_total")
    failures = meta.fetch("failures_sample")
    assert failures.any? { |h| h.fetch("tool_call_id") == "tc_1" && h.fetch("reason") == "name_not_in_visible_tools" }
  end
end
