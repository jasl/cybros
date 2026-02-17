require "test_helper"

class DAG::NodePayloadTest < ActiveSupport::TestCase
  test "tool_call output_preview truncates long string results" do
    long_result = "a" * (DAG::NodePayload::PREVIEW_MAX_CHARS + 50)
    payload = DAG::NodePayloads::ToolCall.create!(output: { "result" => long_result })

    assert payload.output_preview["result"].is_a?(String)
    assert_operator payload.output_preview["result"].length, :<=, DAG::NodePayload::PREVIEW_MAX_CHARS
  end

  test "tool_call output_preview serializes non-string results" do
    payload = DAG::NodePayloads::ToolCall.create!(output: { "result" => { "a" => "b" * 500 } })

    assert payload.output_preview["result"].is_a?(String)
    assert_operator payload.output_preview["result"].length, :<=, DAG::NodePayload::PREVIEW_MAX_CHARS
    assert_includes payload.output_preview["result"], "\"a\""
  end

  test "tool_call output_preview prefers result when output has multiple keys" do
    payload = DAG::NodePayloads::ToolCall.create!(output: { "result" => "ok", "other" => "x" })

    assert payload.output_preview.key?("result")
    assert_not payload.output_preview.key?("json")
    assert_not payload.output_preview.key?("other")
  end

  test "tool_call apply_finished_content! writes result and syncs output_preview" do
    payload = DAG::NodePayloads::ToolCall.create!

    payload.apply_finished_content!("done")
    payload.save!

    assert_equal "done", payload.output["result"]
    assert_equal "done", payload.output_preview["result"]
  end
end
