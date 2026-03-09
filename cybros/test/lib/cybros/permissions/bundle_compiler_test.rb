require "test_helper"

class Cybros::Permissions::BundleCompilerTest < ActiveSupport::TestCase
  test "conservative mode allows read tools and confirms mutate, delegate, and unknown tools" do
    bundle = Cybros::Permissions::BundleCompiler.compile(permission_mode: "conservative", tools_registry: build_tools_registry)

    assert_equal "conservative", bundle.dig(:summary, "permission_mode")
    assert_equal "confirm", bundle.dig(:summary, "tool_defaults", "unknown")
    assert_equal "confirm", bundle.dig(:summary, "target_switch", "different_visible_target")

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)
    policy = bundle.fetch(:tool_policy)

    assert_equal :allow, policy.authorize(name: "memory_search", arguments: { "query" => "notes" }, context: ctx).outcome
    assert_equal :allow, policy.authorize(name: "skills_list", arguments: {}, context: ctx).outcome
    assert_equal :confirm, policy.authorize(name: "memory_store", arguments: { "content" => "remember this" }, context: ctx).outcome
    assert_equal :confirm, policy.authorize(name: "subagent_run", arguments: { "name" => "worker", "prompt" => "do it" }, context: ctx).outcome
    assert_equal :confirm, policy.authorize(name: "custom_unknown", arguments: {}, context: ctx).outcome
  end

  test "default mode allows read and mutate tools but still confirms delegate and unknown tools" do
    bundle = Cybros::Permissions::BundleCompiler.compile(permission_mode: "default", tools_registry: build_tools_registry)

    assert_equal "default", bundle.dig(:summary, "permission_mode")
    assert_equal "allow", bundle.dig(:summary, "tool_defaults", "mutate")
    assert_equal "confirm", bundle.dig(:summary, "tool_defaults", "delegate")

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)
    policy = bundle.fetch(:tool_policy)

    assert_equal :allow, policy.authorize(name: "memory_search", arguments: { "query" => "notes" }, context: ctx).outcome
    assert_equal :allow, policy.authorize(name: "memory_store", arguments: { "content" => "remember this" }, context: ctx).outcome
    assert_equal :confirm, policy.authorize(name: "subagent_spawn", arguments: { "name" => "worker", "prompt" => "go" }, context: ctx).outcome
    assert_equal :confirm, policy.authorize(name: "custom_unknown", arguments: {}, context: ctx).outcome
  end

  test "full access mode allows all visible tools" do
    bundle = Cybros::Permissions::BundleCompiler.compile(permission_mode: "full_access", tools_registry: build_tools_registry)

    assert_equal "full_access", bundle.dig(:summary, "permission_mode")
    assert_equal "confirm", bundle.dig(:summary, "tool_defaults", "unknown")
    assert_equal "allow", bundle.dig(:summary, "target_switch", "different_visible_target")

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)
    policy = bundle.fetch(:tool_policy)

    assert_equal :allow, policy.authorize(name: "memory_search", arguments: { "query" => "notes" }, context: ctx).outcome
    assert_equal :allow, policy.authorize(name: "memory_store", arguments: { "content" => "remember this" }, context: ctx).outcome
    assert_equal :allow, policy.authorize(name: "subagent_spawn", arguments: { "name" => "worker", "prompt" => "go" }, context: ctx).outcome
    assert_equal :confirm, policy.authorize(name: "custom_unknown", arguments: {}, context: ctx).outcome
  end

  test "rejects unknown permission modes" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::Permissions::BundleCompiler.compile(permission_mode: "anything_goes", tools_registry: build_tools_registry)
      end

    assert_equal "cybros.permissions.bundle_compiler.permission_mode_invalid", error.code
  end

  private

    def build_tools_registry
      registry = AgentCore::Resources::Tools::Registry.new
      registry.register_many(Cybros::Subagent::Tools.build)
      registry.register_memory_store(AgentCore::Resources::Memory::InMemory.new)

      skills_dir = Rails.root.join("test/lib/fixtures/skills")
      skills_store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: [skills_dir.to_s])
      registry.register_skills_store(skills_store)

      registry.register(
        AgentCore::Resources::Tools::Tool.new(
          name: "custom_unknown",
          description: "Tool without stable permission metadata.",
          parameters: { type: "object", additionalProperties: false },
        ) do |_args, **|
          AgentCore::Resources::Tools::ToolResult.success(text: "ok")
        end
      )

      registry
    end
end
