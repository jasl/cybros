# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Tools::Policy::ProfiledTest < Minitest::Test
  def test_filter_limits_tool_visibility_by_profile
    delegate = AgentCore::Resources::Tools::Policy::AllowAll.new
    policy =
      AgentCore::Resources::Tools::Policy::Profiled.new(
        allowed: ["read", "skills_*", /mcp__/],
        delegate: delegate,
      )

    tools = [
      { name: "read", description: "ok", parameters: {} },
      { name: "write", description: "no", parameters: {} },
      { name: "skills_list", description: "ok", parameters: {} },
      { type: "function", function: { name: "mcp__server__echo", description: "ok", parameters: {} } },
      { type: "function", function: { name: "other", description: "no", parameters: {} } },
    ]

    ctx = AgentCore::ExecutionContext.from(nil)
    filtered = policy.filter(tools: tools, context: ctx)

    names =
      filtered.map do |t|
        t.fetch(:name, t.fetch("name", t.dig(:function, :name) || t.dig("function", "name")))
      end

    assert_equal ["read", "skills_list", "mcp__server__echo"], names
  end

  def test_group_refs_expand_via_tool_groups
    delegate = AgentCore::Resources::Tools::Policy::AllowAll.new
    groups = { "fs" => ["read", "write"] }

    policy =
      AgentCore::Resources::Tools::Policy::Profiled.new(
        allowed: ["group:fs"],
        delegate: delegate,
        tool_groups: groups,
      )

    tools = [
      { name: "read", description: "ok", parameters: {} },
      { name: "write", description: "ok", parameters: {} },
      { name: "other", description: "no", parameters: {} },
    ]

    ctx = AgentCore::ExecutionContext.from(nil)
    filtered = policy.filter(tools: tools, context: ctx)

    names = filtered.map { |t| t.fetch(:name, t.fetch("name", "")) }
    assert_equal ["read", "write"], names
  end

  def test_authorize_denies_when_tool_not_in_profile
    delegate = AgentCore::Resources::Tools::Policy::AllowAll.new
    policy = AgentCore::Resources::Tools::Policy::Profiled.new(allowed: ["read"], delegate: delegate)

    ctx = AgentCore::ExecutionContext.from(nil)

    allowed = policy.authorize(name: "read", arguments: {}, context: ctx)
    assert allowed.allowed?

    denied = policy.authorize(name: "write", arguments: {}, context: ctx)
    assert denied.denied?
    assert_equal "tool_not_in_profile", denied.reason
  end

  def test_star_allows_all
    delegate = AgentCore::Resources::Tools::Policy::AllowAll.new
    policy = AgentCore::Resources::Tools::Policy::Profiled.new(allowed: ["*"], delegate: delegate)

    ctx = AgentCore::ExecutionContext.from(nil)

    decision = policy.authorize(name: "anything", arguments: {}, context: ctx)
    assert decision.allowed?
  end
end
