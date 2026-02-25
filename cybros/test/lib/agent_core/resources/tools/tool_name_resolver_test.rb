# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Tools::ToolNameResolverTest < Minitest::Test
  def test_normalize_key_handles_case_camel_and_separators
    n = AgentCore::Resources::Tools::ToolNameResolver.method(:normalize_key)

    assert_equal "memory_search", n.call("memory.search")
    assert_equal "memory_search", n.call("memory-search")
    assert_equal "memory_search", n.call("memorySearch")
    assert_equal "skills_list", n.call("SkillsList")
    assert_equal "skills_list", n.call("SKILLS_LIST")
    assert_equal "foo_bar", n.call(" foo..bar  ")
    assert_equal "foo_bar", n.call("foo---bar")
    assert_equal "foo_bar", n.call("foo__bar")
  end

  def test_build_normalize_index_raises_on_collision
    err =
      assert_raises(AgentCore::Resources::Tools::ToolNameConflictError) do
        AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(["foo-bar", "foo_bar"])
      end

    assert_match(/normalize collisions/i, err.message)
    assert_match(/foo_bar/, err.message)
  end

  def test_resolve_prefers_alias_over_normalize
    tools = ["foo-bar"]
    include_check = ->(name) { tools.include?(name) }
    normalize_index = AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(tools)

    res =
      AgentCore::Resources::Tools::ToolNameResolver.resolve(
        "foo.bar",
        include_check: include_check,
        aliases: { "foo.bar" => "foo-bar" },
        enable_normalize_fallback: true,
        normalize_index: normalize_index,
      )

    assert_equal "foo.bar", res.requested_name
    assert_equal "foo-bar", res.resolved_name
    assert_equal :alias, res.method
  end

  def test_resolve_normalize_maps_to_canonical_tool_name
    tools = ["foo-bar"]
    include_check = ->(name) { tools.include?(name) }
    normalize_index = AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(tools)

    res =
      AgentCore::Resources::Tools::ToolNameResolver.resolve(
        "foo_bar",
        include_check: include_check,
        aliases: {},
        enable_normalize_fallback: true,
        normalize_index: normalize_index,
      )

    assert_equal "foo_bar", res.requested_name
    assert_equal "foo-bar", res.resolved_name
    assert_equal :normalized, res.method
  end

  def test_resolve_normalize_requires_index
    tools = ["foo-bar"]
    include_check = ->(name) { tools.include?(name) }

    res =
      AgentCore::Resources::Tools::ToolNameResolver.resolve(
        "foo_bar",
        include_check: include_check,
        aliases: {},
        enable_normalize_fallback: true,
        normalize_index: nil,
      )

    assert_equal :unknown, res.method
    assert_equal "foo_bar", res.resolved_name
  end

  def test_resolve_default_aliases_include_subagent_tools
    tools = ["subagent_spawn", "subagent_poll"]
    include_check = ->(name) { tools.include?(name) }

    res =
      AgentCore::Resources::Tools::ToolNameResolver.resolve(
        "subagent.spawn",
        include_check: include_check,
        aliases: {},
      )

    assert_equal "subagent_spawn", res.resolved_name
    assert_equal :alias, res.method

    res =
      AgentCore::Resources::Tools::ToolNameResolver.resolve(
        "subagent-poll",
        include_check: include_check,
        aliases: {},
      )

    assert_equal "subagent_poll", res.resolved_name
    assert_equal :alias, res.method
  end
end
