require "test_helper"

class AgentCore::Resources::Tools::Policy::PrefixRulesTest < Minitest::Test
  def test_allows_when_command_has_approved_prefix
    delegate = AgentCore::Resources::Tools::Policy::DenyAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PrefixRules.new(
        delegate: delegate,
        rules: [
          { tools: ["exec"], argument_key: "command", prefixes: ["git status"], decision: { outcome: "allow" } },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    allowed = policy.authorize(name: "exec", arguments: { "command" => "git status -sb" }, context: ctx)
    assert allowed.allowed?

    denied = policy.authorize(name: "exec", arguments: { "command" => "rm -rf /" }, context: ctx)
    assert denied.denied?
  end

  def test_string_prefix_requires_token_boundary
    delegate = AgentCore::Resources::Tools::Policy::DenyAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PrefixRules.new(
        delegate: delegate,
        rules: [
          { tools: ["exec"], argument_key: "command", prefixes: ["git status"], decision: { outcome: "allow" } },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    denied = policy.authorize(name: "exec", arguments: { "command" => "git statusx" }, context: ctx)
    assert denied.denied?
  end

  def test_string_prefix_rejects_shell_operators
    delegate = AgentCore::Resources::Tools::Policy::DenyAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PrefixRules.new(
        delegate: delegate,
        rules: [
          { tools: ["exec"], argument_key: "command", prefixes: ["git status"], decision: { outcome: "allow" } },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    denied = policy.authorize(name: "exec", arguments: { "command" => "git status; rm -rf /" }, context: ctx)
    assert denied.denied?
  end

  def test_command_arrays_are_normalized
    delegate = AgentCore::Resources::Tools::Policy::DenyAll.new

    policy =
      AgentCore::Resources::Tools::Policy::PrefixRules.new(
        delegate: delegate,
        rules: [
          { tools: ["exec"], argument_key: "command", prefixes: ["git status"], decision: { outcome: "allow" } },
        ],
      )

    ctx = AgentCore::ExecutionContext.from(nil)

    allowed = policy.authorize(name: "exec", arguments: { "command" => ["git", "status", "-sb"] }, context: ctx)
    assert allowed.allowed?
  end
end
