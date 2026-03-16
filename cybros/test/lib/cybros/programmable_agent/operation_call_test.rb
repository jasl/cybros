require "test_helper"

class Cybros::ProgrammableAgent::OperationCallTest < ActiveSupport::TestCase
  test "tool normalizes the common operation envelope" do
    call =
      Cybros::ProgrammableAgent::OperationCall.tool(
        logical_tool_name: :search,
        arguments: {
          query: "TODO",
          filters: {
            path: "app/models",
          },
        },
        reason: "  inspect repo state  ",
        origin: "  direct_tool_loop  ",
        approval_hint: {
          mode: :confirm,
        },
        idempotency_key: "  direct.search.tc_1  ",
        tool_call_id: "  tc_1  ",
      )

    assert_equal "tc_1", call.tool_call_id
    assert_equal "search", call.logical_tool_name
    assert_equal({"query" => "TODO", "filters" => {"path" => "app/models"}}, call.arguments)
    assert_equal "inspect repo state", call.reason
    assert_equal "direct_tool_loop", call.origin
    assert_equal({"mode" => "confirm"}, call.approval_hint)
    assert_equal "direct.search.tc_1", call.idempotency_key
  end

  test "tool generates a tool_call_id when one is omitted" do
    call =
      Cybros::ProgrammableAgent::OperationCall.tool(
        logical_tool_name: "search",
        arguments: { query: "TODO" },
        reason: "inspect repo state",
        origin: "direct_tool_loop",
      )

    assert_match(/\Aopcall_/, call.tool_call_id)
  end

  test "subagent_spawn preserves the runtime tool name" do
    call =
      Cybros::ProgrammableAgent::OperationCall.subagent_spawn(
        arguments: { name: "helper", prompt: "Summarize this" },
        reason: "delegate repo inspection",
        origin: "bootstrap_proposal",
        tool_call_id: "  tc_spawn  ",
      )

    assert_equal "tc_spawn", call.tool_call_id
    assert_equal "subagent_spawn", call.logical_tool_name
    assert_equal({"name" => "helper", "prompt" => "Summarize this"}, call.arguments)
    assert_equal "delegate repo inspection", call.reason
    assert_equal "bootstrap_proposal", call.origin
  end
end
