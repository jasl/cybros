require "test_helper"

class ConversationInputPolicyResolverTest < ActiveSupport::TestCase
  test "conversation metadata overrides agent profile defaults" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "interrupt_new_turn",
            "input_coalescing" => { "window_ms" => 2500 },
          },
        },
      )

    policy = conversation.resolved_input_policy

    assert_equal "interrupt_new_turn", policy.fetch("running_input_policy")
    assert_equal true, policy.dig("input_coalescing", "enabled")
    assert_equal 2500, policy.dig("input_coalescing", "window_ms")
    assert_equal "discard_context", policy.fetch("interrupted_output_policy")
  end

  test "app override wins over conversation metadata override" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "interrupt_new_turn",
          },
        },
      )

    policy =
      conversation.resolved_input_policy(
        app_override: {
          "running_input_policy" => "queue",
          "steer_capability" => false,
        },
      )

    assert_equal "queue", policy.fetch("running_input_policy")
    assert_equal false, policy.fetch("steer_capability")
  end

  test "app override accepts action controller parameters from web requests" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
        },
      )

    policy =
      conversation.resolved_input_policy(
        app_override:
          ActionController::Parameters.new(
            running_input_policy: "interrupt_new_turn",
            input_coalescing: { window_ms: 0 },
          ),
      )

    assert_equal "interrupt_new_turn", policy.fetch("running_input_policy")
    assert_equal 0, policy.dig("input_coalescing", "window_ms")
  end

  test "action-level interrupted output override wins over static defaults for retry and steer" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "interrupted_output_policy" => "keep_context",
          },
        },
      )

    retry_policy =
      conversation.resolved_input_policy(
        action: "retry",
        interrupted_output_policy_override: "discard_context",
      )
    steer_policy =
      conversation.resolved_input_policy(
        action: "steer_current_turn",
        interrupted_output_policy_override: "discard_context",
      )

    assert_equal "discard_context", retry_policy.fetch("interrupted_output_policy")
    assert_equal "discard_context", steer_policy.fetch("interrupted_output_policy")
  end

  test "selected agent program manifest drives defaults when no legacy agent_profile is stored" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "key" => "main" },
        },
      )

    policy = conversation.resolved_input_policy

    assert_equal "queue", policy.fetch("running_input_policy")
    assert_equal "keep_context", policy.fetch("interrupted_output_policy")
    assert_equal true, policy.fetch("steer_capability")
  end
end
