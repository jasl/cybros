require "test_helper"

class AgentCore::Resources::Tools::Policy::RulesetTest < Minitest::Test
  def test_deny_precedes_confirm_and_allow
    policy =
      AgentCore::Resources::Tools::Policy::Ruleset.new(
        delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
        deny: [{ tools: ["echo"], reason: "no_echo" }],
        confirm: [{ tools: ["echo"], reason: "echo_needs_review" }],
        allow: [{ tools: ["echo"], reason: "ok" }],
      )

    ctx = AgentCore::ExecutionContext.from(nil)
    decision = policy.authorize(name: "echo", arguments: {}, context: ctx)

    assert decision.denied?
    assert_equal "no_echo", decision.reason
  end

  def test_confirm_precedes_allow
    policy =
      AgentCore::Resources::Tools::Policy::Ruleset.new(
        delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
        confirm: [{ tools: ["echo"], reason: "echo_needs_review" }],
        allow: [{ tools: ["echo"], reason: "ok" }],
      )

    ctx = AgentCore::ExecutionContext.from(nil)
    decision = policy.authorize(name: "echo", arguments: {}, context: ctx)

    assert decision.requires_confirmation?
    assert_equal "echo_needs_review", decision.reason
  end

  def test_first_match_wins_within_category
    policy =
      AgentCore::Resources::Tools::Policy::Ruleset.new(
        delegate: AgentCore::Resources::Tools::Policy::AllowAll.new,
        confirm: [
          { tools: ["echo"], reason: "first" },
          { tools: ["echo"], reason: "second" },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)
    decision = policy.authorize(name: "echo", arguments: {}, context: ctx)

    assert decision.requires_confirmation?
    assert_equal "first", decision.reason
  end
end
