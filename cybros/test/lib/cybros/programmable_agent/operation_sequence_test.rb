require "test_helper"

class Cybros::ProgrammableAgent::OperationSequenceTest < ActiveSupport::TestCase
  test "serializes ordered calls into queue-ready payloads" do
    sequence = Cybros::ProgrammableAgent::OperationSequence.new(origin: "bootstrap_proposal")

    sequence <<
      Cybros::ProgrammableAgent::OperationCall.tool(
        logical_tool_name: "search",
        arguments: { query: "TODO" },
        reason: "inspect repo state",
        idempotency_key: "bootstrap.search",
      )
    sequence <<
      Cybros::ProgrammableAgent::OperationCall.subagent_spawn(
        arguments: { name: "helper", prompt: "Summarize this" },
        reason: "delegate repo inspection",
        approval_hint: { mode: "confirm" },
      )

    payloads = sequence.to_queue_payloads

    assert_equal 2, payloads.length
    assert_match(/\Aopseq_/, sequence.sequence_id)

    assert_equal(
      {
        "tool_call_id" => payloads.first.fetch("tool_call_id"),
        "logical_tool_name" => "search",
        "arguments" => { "query" => "TODO" },
        "reason" => "inspect repo state",
        "origin" => "bootstrap_proposal",
        "approval_hint" => nil,
        "idempotency_key" => "bootstrap.search",
        "sequence_id" => sequence.sequence_id,
        "step_index" => 0,
        "step_count" => 2,
      },
      payloads.first,
    )
    assert_match(/\Aopcall_/, payloads.first.fetch("tool_call_id"))

    assert_equal(
      {
        "tool_call_id" => payloads.second.fetch("tool_call_id"),
        "logical_tool_name" => "subagent_spawn",
        "arguments" => { "name" => "helper", "prompt" => "Summarize this" },
        "reason" => "delegate repo inspection",
        "origin" => "bootstrap_proposal",
        "approval_hint" => { "mode" => "confirm" },
        "idempotency_key" => nil,
        "sequence_id" => sequence.sequence_id,
        "step_index" => 1,
        "step_count" => 2,
      },
      payloads.second,
    )
    assert_match(/\Aopcall_/, payloads.second.fetch("tool_call_id"))
  end

  test "explicit call origins override the sequence origin" do
    sequence = Cybros::ProgrammableAgent::OperationSequence.new(origin: "bootstrap_proposal")

    sequence <<
      Cybros::ProgrammableAgent::OperationCall.tool(
        logical_tool_name: "search",
        arguments: { query: "TODO" },
        reason: "inspect repo state",
        origin: "direct_tool_loop",
      )

    assert_equal "direct_tool_loop", sequence.to_queue_payloads.sole.fetch("origin")
  end
end
