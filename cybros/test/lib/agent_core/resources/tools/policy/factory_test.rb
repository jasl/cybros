require "test_helper"

class AgentCore::Resources::Tools::Policy::FactoryTest < Minitest::Test
  def test_empty_config_returns_deny_all
    policy = AgentCore::Resources::Tools::Policy::Factory.build({})
    assert_instance_of AgentCore::Resources::Tools::Policy::DenyAll, policy
  end

  def test_default_outcome_deny_builds_deny_all_visible
    policy =
      AgentCore::Resources::Tools::Policy::Factory.build(
        {
          "version" => 1,
          "default" => { "outcome" => "deny", "reason" => "no_tools" },
        },
      )

    assert_instance_of AgentCore::Resources::Tools::Policy::DenyAllVisible, policy

    ctx = AgentCore::ExecutionContext.from(nil)
    tools = [{ "name" => "echo" }]
    assert_equal tools, policy.filter(tools: tools, context: ctx)

    decision = policy.authorize(name: "echo", arguments: {}, context: ctx)
    assert decision.denied?
    assert_equal "no_tools", decision.reason
  end

  def test_unknown_keys_raise_validation_error
    error =
      assert_raises(AgentCore::ValidationError) do
        AgentCore::Resources::Tools::Policy::Factory.build({ "version" => 1, "wat" => true })
      end

    assert_equal "agent_core.tools.policy.factory.unknown_keys", error.code
    assert_equal ["wat"], error.details.fetch(:unknown)
  end

  def test_type_errors_raise_validation_error
    error =
      assert_raises(AgentCore::ValidationError) do
        AgentCore::Resources::Tools::Policy::Factory.build({ "version" => 1, "rules" => "nope" })
      end

    assert_equal "agent_core.tools.policy.factory.rules_must_be_a_hash_got", error.code
  end

  def test_version_not_supported_raises_validation_error
    error =
      assert_raises(AgentCore::ValidationError) do
        AgentCore::Resources::Tools::Policy::Factory.build({ "version" => 2, "default" => { "outcome" => "confirm" } })
      end

    assert_equal "agent_core.tools.policy.factory.unsupported_version", error.code
  end

  def test_builds_ruleset_that_matches_mcp_and_subagent_tools
    policy =
      AgentCore::Resources::Tools::Policy::Factory.build(
        {
          "version" => 1,
          "default" => { "outcome" => "confirm", "reason" => "needs_approval" },
          "rules" => {
            "deny" => [{ "tools" => ["subagent_*"], "reason" => "no_subagents" }],
            "confirm" => [
              {
                "tools" => ["mcp_github__*"],
                "reason" => "mcp_needs_review",
                "required" => true,
                "deny_effect" => "block",
              },
            ],
            "allow" => [{ "tools" => ["echo"], "reason" => "ok" }],
          },
        },
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    denied = policy.authorize(name: "subagent_spawn", arguments: {}, context: ctx)
    assert denied.denied?
    assert_equal "no_subagents", denied.reason

    confirmed = policy.authorize(name: "mcp_github__echo", arguments: { "text" => "hi" }, context: ctx)
    assert confirmed.requires_confirmation?
    assert_equal "mcp_needs_review", confirmed.reason
    assert_equal true, confirmed.required
    assert_equal "block", confirmed.deny_effect

    allowed = policy.authorize(name: "echo", arguments: { "text" => "hi" }, context: ctx)
    assert allowed.allowed?
    assert_equal "ok", allowed.reason
  end
end
