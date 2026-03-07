require "test_helper"

class DagDebugCommandStatusTest < ActiveSupport::TestCase
  test "command_exit_status returns non-zero for failed retry results" do
    result = {
      "source_node" => { "id" => "node_src", "state" => "errored" },
      "created_node" => { "id" => "node_new", "state" => "errored", "metadata" => { "error" => "boom" } },
      "conversation_run_id" => "run_1",
    }

    status = Cybros::CLI::DAGDebug.command_exit_status(command: "retry", result: result)

    assert_equal 1, status
  end

  test "command_exit_status returns non-zero for failed capture execution" do
    result = {
      "source_node" => { "id" => "node_src", "state" => "pending" },
      "target_node" => { "id" => "node_src", "state" => "pending" },
      "execution" => { "mode" => "runner", "result_state" => "errored", "error" => "boom" },
      "captured_calls" => [],
      "wire_calls" => [],
    }

    status = Cybros::CLI::DAGDebug.command_exit_status(command: "capture", result: result)

    assert_equal 1, status
  end

  test "command_exit_status returns non-zero for failed smoke runs" do
    result = {
      "conversation" => { "id" => "conv_1", "title" => "Smoke" },
      "user_node" => { "id" => "user_1", "state" => "finished", "body_input" => { "content" => "Hello" } },
      "agent_node" => { "id" => "agent_1", "state" => "errored", "metadata" => { "error" => "boom" } },
    }

    status = Cybros::CLI::DAGDebug.command_exit_status(command: "smoke", result: result)

    assert_equal 1, status
  end

  test "command_exit_status keeps execution exports observation-only" do
    result = {
      "turn_id" => "turn_1",
      "status" => "failed",
      "phase" => "terminal",
      "activities" => [
        { "activity_id" => "task:1", "status" => "failed" },
      ],
    }

    status = Cybros::CLI::DAGDebug.command_exit_status(command: "execution", result: result)

    assert_equal 0, status
  end
end
