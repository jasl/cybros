# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Tools::Policy::ToolGroupsTest < Minitest::Test
  def test_expands_group_refs
    groups =
      AgentCore::Resources::Tools::Policy::ToolGroups.new(
        groups: { "fs" => ["read", "write"] },
      )

    assert_equal ["read", "write"], groups.expand(["group:fs"])
  end

  def test_nested_group_refs_expand
    groups =
      AgentCore::Resources::Tools::Policy::ToolGroups.new(
        groups: { "a" => ["group:b"], "b" => ["read"] },
      )

    assert_equal ["read"], groups.expand(["group:a"])
  end

  def test_unknown_group_refs_are_kept
    groups =
      AgentCore::Resources::Tools::Policy::ToolGroups.new(
        groups: { "fs" => ["read"] },
      )

    assert_equal ["group:missing"], groups.expand(["group:missing"])
  end

  def test_cycles_do_not_infinite_loop
    groups =
      AgentCore::Resources::Tools::Policy::ToolGroups.new(
        groups: { "a" => ["group:a"] },
      )

    assert_equal ["group:a"], groups.expand(["group:a"])
  end
end
