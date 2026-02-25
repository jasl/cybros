require "test_helper"

class DAG::NodeBodyTest < ActiveSupport::TestCase
  test "task output_preview truncates long string results" do
    long_result = "a" * (DAG::NodeBody::PREVIEW_MAX_CHARS + 50)
    payload = Messages::Task.create!(output: { "result" => long_result })

    assert payload.output_preview["result"].is_a?(String)
    assert_operator payload.output_preview["result"].length, :<=, DAG::NodeBody::PREVIEW_MAX_CHARS
  end

  test "task output_preview summarizes non-string results" do
    payload = Messages::Task.create!(output: { "result" => { "a" => "b" * 500 } })

    assert payload.output_preview["result"].is_a?(String)
    assert_operator payload.output_preview["result"].length, :<=, DAG::NodeBody::PREVIEW_MAX_CHARS
    assert_includes payload.output_preview["result"], "Hash(size=1"
    assert_includes payload.output_preview["result"], "keys=a"
  end

  test "task output_preview prefers result when output has multiple keys" do
    payload = Messages::Task.create!(output: { "result" => "ok", "other" => "x" })

    assert payload.output_preview.key?("result")
    assert_not payload.output_preview.key?("json")
    assert_not payload.output_preview.key?("other")
  end

  test "task output_preview summarizes array results" do
    payload = Messages::Task.create!(output: { "result" => ["a" * 100, { "k" => 1 }, 123] })

    assert payload.output_preview["result"].is_a?(String)
    assert_operator payload.output_preview["result"].length, :<=, DAG::NodeBody::PREVIEW_MAX_CHARS
    assert_includes payload.output_preview["result"], "Array(len="
    assert_includes payload.output_preview["result"], "sample=["
  end

  test "task apply_finished_content! writes result and syncs output_preview" do
    payload = Messages::Task.create!

    payload.apply_finished_content!("done")
    payload.save!

    assert_equal "done", payload.output["result"]
    assert_equal "done", payload.output_preview["result"]
  end
end
