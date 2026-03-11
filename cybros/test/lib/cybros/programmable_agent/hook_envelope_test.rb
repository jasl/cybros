require "test_helper"

class Cybros::ProgrammableAgent::HookEnvelopeTest < ActiveSupport::TestCase
  test "before_agent_step planning parses a typed planning envelope" do
    envelope =
      Cybros::ProgrammableAgent::HookEnvelope.parse!(
        hook_name: "before_agent_step",
        request_payload: {
          "step" => {
            "phase" => "planning",
          },
        },
        payload: {
          "planning" => {
            "step_plan" => {
              "kind" => "fixture.plan",
            },
            "staged_mutations" => {
              "prompt_buffer_ops" => [
                { "op" => "put", "entry" => { "id" => "entry-1" } },
              ],
            },
            "planned_tasks" => [],
          },
          "actions" => [
            { "type" => "set_step_status", "text" => "Planning" },
          ],
        },
      )

    assert_equal "fixture.plan", envelope.planning.step_plan.fetch("kind")
    assert_equal "put", envelope.planning.staged_mutations.fetch("prompt_buffer_ops").sole.fetch("op")
    assert_equal "set_step_status", envelope.actions.sole.type
  end

  test "non planning hooks reject planning payloads" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "before_finalize_output",
          request_payload: {},
          payload: {
            "planning" => {
              "step_plan" => { "kind" => "fixture.plan" },
            },
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_contract.planning_not_allowed", error.code
  end

  test "planning rejects direct approval_state mutation" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "before_agent_step",
          request_payload: { "step" => { "phase" => "planning" } },
          payload: {
            "planning" => {
              "approval_state" => {
                "status" => "pending_confirmation",
              },
            },
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_contract.approval_state_forbidden", error.code
  end

  test "before_agent_step planning rejects deny actions" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "before_agent_step",
          request_payload: { "step" => { "phase" => "planning" } },
          payload: {
            "actions" => [
              { "type" => "deny", "reason" => "no_plan" },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_policy.deny_not_allowed", error.code
  end

  test "terminal actions must be tail-only" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "on_context_pressure",
          request_payload: {},
          payload: {
            "actions" => [
              { "type" => "halt", "reason" => "stop" },
              { "type" => "set_step_status", "text" => "too late" },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_action.terminal_not_tail", error.code
  end

  test "emit_message forbids later placeholder mutations" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "before_finalize_output",
          request_payload: {},
          payload: {
            "actions" => [
              { "type" => "emit_message", "message" => { "content" => "done" } },
              { "type" => "set_step_status", "text" => "too late" },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_action.emit_message_followup_forbidden", error.code
  end

  test "emit_message forbids a second emit_message in the same envelope" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "before_finalize_output",
          request_payload: {},
          payload: {
            "actions" => [
              { "type" => "emit_message", "message" => { "content" => "done" } },
              { "type" => "emit_message", "message" => { "content" => "again" } },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_action.emit_message_followup_forbidden", error.code
  end

  test "create_task forbids explicit routing metadata authored by the agent" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "on_context_pressure",
          request_payload: {},
          payload: {
            "actions" => [
              {
                "type" => "create_task",
                "logical_tool_name" => "compact_context",
                "input" => {
                  "reason" => "budget pressure",
                  "effective_tool_id" => "effective_tool:manual",
                },
                "placement" => "prepend",
              },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.runtime.task_rewrite_forbidden", error.code
  end

  test "create_task requires a logical tool name" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "on_context_pressure",
          request_payload: {},
          payload: {
            "actions" => [
              {
                "type" => "create_task",
                "input" => { "reason" => "budget pressure" },
                "placement" => "prepend",
              },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_action.create_task_missing_logical_tool_name", error.code
  end

  test "set_step_status requires text" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "after_task_notice",
          request_payload: {},
          payload: {
            "actions" => [
              { "type" => "set_step_status" },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_action.set_step_status_missing_text", error.code
  end

  test "after_task_notice forbids prepend follow-up tasks" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookEnvelope.parse!(
          hook_name: "after_task_notice",
          request_payload: {},
          payload: {
            "actions" => [
              {
                "type" => "create_task",
                "logical_tool_name" => "compact_context",
                "input" => { "reason" => "provider_error" },
                "placement" => "prepend",
              },
            ],
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_policy.create_task_not_allowed", error.code
  end
end
