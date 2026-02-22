# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Tools::Policy::PatternRulesTest < Minitest::Test
  def test_matches_tool_name_and_argument_glob
    delegate = AgentCore::Resources::Tools::Policy::AllowAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PatternRules.new(
        delegate: delegate,
        rules: [
          {
            tools: ["read"],
            arguments: [
              { key: "path", glob: "config/**", normalize: "path" },
            ],
            decision: { outcome: "deny", reason: "no_config_reads" },
          },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    denied = policy.authorize(name: "read", arguments: { "path" => "config/app.yml" }, context: ctx)
    assert denied.denied?
    assert_equal "no_config_reads", denied.reason

    allowed = policy.authorize(name: "read", arguments: { "path" => "README.md" }, context: ctx)
    assert allowed.allowed?
  end

  def test_glob_star_does_not_cross_slash
    delegate = AgentCore::Resources::Tools::Policy::AllowAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PatternRules.new(
        delegate: delegate,
        rules: [
          {
            tools: ["read"],
            arguments: [{ key: "path", glob: "config/*", normalize: "path" }],
            decision: { outcome: "deny", reason: "no_config_files" },
          },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    denied = policy.authorize(name: "read", arguments: { "path" => "config/app.yml" }, context: ctx)
    assert denied.denied?

    allowed = policy.authorize(name: "read", arguments: { "path" => "config/subdir/app.yml" }, context: ctx)
    assert allowed.allowed?
  end

  def test_present_and_absent_matchers
    delegate = AgentCore::Resources::Tools::Policy::AllowAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PatternRules.new(
        delegate: delegate,
        rules: [
          {
            tools: ["read"],
            arguments: [{ key: "path", present: true, normalize: "path" }],
            decision: { outcome: "deny", reason: "path_required_but_denied" },
          },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    allowed = policy.authorize(name: "read", arguments: {}, context: ctx)
    assert allowed.allowed?

    denied = policy.authorize(name: "read", arguments: { "path" => "README.md" }, context: ctx)
    assert denied.denied?
  end

  def test_nested_path_dig
    delegate = AgentCore::Resources::Tools::Policy::DenyAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PatternRules.new(
        delegate: delegate,
        rules: [
          {
            tools: ["read"],
            arguments: [{ path: ["options", "path"], equals: "README.md", normalize: "path" }],
            decision: { outcome: "allow" },
          },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    allowed =
      policy.authorize(
        name: "read",
        arguments: { "options" => { "path" => "README.md" } },
        context: ctx,
      )
    assert allowed.allowed?
  end

  def test_rules_are_checked_in_order
    delegate = AgentCore::Resources::Tools::Policy::DenyAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PatternRules.new(
        delegate: delegate,
        rules: [
          {
            tools: ["read"],
            arguments: [{ key: "path", glob: "config/**", normalize: "path" }],
            decision: { outcome: "deny", reason: "first" },
          },
          {
            tools: ["read"],
            arguments: [{ key: "path", glob: "config/app.yml", normalize: "path" }],
            decision: { outcome: "allow" },
          },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    denied = policy.authorize(name: "read", arguments: { "path" => "config/app.yml" }, context: ctx)
    assert denied.denied?
    assert_equal "first", denied.reason
  end

  def test_supports_group_refs_in_tools
    delegate = AgentCore::Resources::Tools::Policy::DenyAll.new
    tool_groups = { "fs" => ["read"] }

    policy =
      AgentCore::Resources::Tools::Policy::PatternRules.new(
        delegate: delegate,
        tool_groups: tool_groups,
        rules: [
          {
            tools: ["group:fs"],
            arguments: [{ key: "path", equals: "README.md", normalize: "path" }],
            decision: { outcome: "allow" },
          },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    allowed = policy.authorize(name: "read", arguments: { "path" => "README.md" }, context: ctx)
    assert allowed.allowed?
  end
end
