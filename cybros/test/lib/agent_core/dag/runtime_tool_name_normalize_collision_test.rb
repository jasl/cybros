require "test_helper"

class AgentCore::DAG::RuntimeToolNameNormalizeCollisionTest < Minitest::Test
  def test_runtime_raises_on_normalize_key_collision_when_enabled
    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(AgentCore::Resources::Tools::Tool.new(name: "foo-bar", description: "") { })
    registry.register(AgentCore::Resources::Tools::Tool.new(name: "foo_bar", description: "") { })

    assert_raises(AgentCore::Resources::Tools::ToolNameConflictError) do
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: registry,
        tool_name_normalize_fallback: true,
      )
    end
  end

  def test_runtime_raises_on_alias_key_shadowed_by_existing_tool_name
    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(AgentCore::Resources::Tools::Tool.new(name: "echo", description: "") { })

    assert_raises(AgentCore::Resources::Tools::ToolNameConflictError) do
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: registry,
        tool_name_aliases: { "echo" => "echo_other" },
      )
    end
  end

  def test_runtime_allows_self_mapping_alias_even_if_tool_exists
    registry = AgentCore::Resources::Tools::Registry.new
    registry.register(AgentCore::Resources::Tools::Tool.new(name: "echo", description: "") { })

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: registry,
        tool_name_aliases: { "echo" => "echo" },
      )

    assert_equal({ "echo" => "echo" }, runtime.tool_name_aliases)
  end
end
