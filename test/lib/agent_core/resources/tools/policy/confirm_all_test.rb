# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Tools::Policy::ConfirmAllTest < Minitest::Test
  def test_filter_is_passthrough
    policy = AgentCore::Resources::Tools::Policy::ConfirmAll.new
    ctx = AgentCore::ExecutionContext.from(nil)

    tools = [{ "name" => "echo" }, { "name" => "exec" }]
    assert_equal tools, policy.filter(tools: tools, context: ctx)
  end

  def test_authorize_always_confirms
    policy =
      AgentCore::Resources::Tools::Policy::ConfirmAll.new(
        reason: "mcp_needs_review",
        required: true,
        deny_effect: "block",
      )

    ctx = AgentCore::ExecutionContext.from(nil)
    decision = policy.authorize(name: "echo", arguments: { "text" => "hi" }, context: ctx)

    assert decision.requires_confirmation?
    assert_equal "mcp_needs_review", decision.reason
    assert_equal true, decision.required
    assert_equal "block", decision.deny_effect
  end
end

