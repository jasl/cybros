require "test_helper"

class AgentCore::ToolCallTest < Minitest::Test
  def test_arguments_raw_is_truncated
    raw = "a" * 10_000

    tc =
      AgentCore::ToolCall.new(
        id: "tc_1",
        name: "echo",
        arguments: {},
        arguments_parse_error: :invalid_json,
        arguments_raw: raw,
      )

    assert tc.arguments_raw.bytesize <= AgentCore::ToolCall::MAX_ARGUMENTS_RAW_BYTES
  end

  def test_to_h_includes_arguments_raw_only_when_parse_error_present
    tc =
      AgentCore::ToolCall.new(
        id: "tc_1",
        name: "echo",
        arguments: { "text" => "hi" },
        arguments_raw: "{\"text\":\"hi\"}",
        arguments_parse_error: nil,
      )

    refute tc.to_h.key?(:arguments_raw)

    bad =
      AgentCore::ToolCall.new(
        id: "tc_1",
        name: "echo",
        arguments: {},
        arguments_parse_error: :invalid_json,
        arguments_raw: "not json",
      )

    assert_equal "not json", bad.to_h.fetch(:arguments_raw)
  end
end
