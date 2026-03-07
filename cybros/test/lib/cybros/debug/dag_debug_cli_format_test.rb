require "test_helper"
require Rails.root.join("script/dag_debug").to_s

class DagDebugCliFormatTest < ActiveSupport::TestCase
  test "usage omits unsafe direct execute flag" do
    usage = DagDebugCLI.usage

    refute_includes usage, "--unsafe-direct-execute"
    assert_includes usage, "capture <node_id> [--execute] [--retry-first] [--json]"
    assert_includes usage, "execution <node_id> [--json]"
  end

  test "pretty_smoke marks ephemeral conversations clearly" do
    result = {
      "conversation" => {
        "id" => "conv_1",
        "title" => "Debug smoke",
        "ephemeral" => true,
      },
      "user_node" => { "id" => "user_1", "state" => "finished", "body_input" => { "content" => "Hello" } },
      "agent_node" => {
        "id" => "agent_1",
        "state" => "finished",
        "metadata" => {},
        "body_output" => { "content" => "World" },
      },
    }

    output = DagDebugCLI.pretty_smoke(result)

    assert_includes output, "Conversation: conv_1 Debug smoke (ephemeral; deleted after run)"
  end

  test "pretty_execution renders turn execution diagnostics" do
    result = {
      "turn_id" => "turn_1",
      "status" => "running",
      "phase" => "execution",
      "event_cursor" => "evt_2",
      "activities" => [
        {
          "sequence" => 7,
          "activity_id" => "task:1",
          "title" => "memory_search",
          "kind" => "tool_call",
          "status" => "running",
          "phase" => "execution",
        },
      ],
    }

    output = DagDebugCLI.pretty_execution(result)

    assert_includes output, "Turn: turn_1 running/execution cursor=evt_2"
    assert_includes output, "[7] running tool_call memory_search"
  end
end
