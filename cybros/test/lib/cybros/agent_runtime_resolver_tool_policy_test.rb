# frozen_string_literal: true

require "test_helper"

class Cybros::AgentRuntimeResolverToolPolicyTest < ActiveSupport::TestCase
  test "Phase 0 policy auto-allows memory_* and skills_*; confirms other tools by default" do
    tools_registry = AgentCore::Resources::Tools::Registry.new

    skills_dir = Rails.root.join("test/lib/fixtures/skills")
    skills_store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: [skills_dir.to_s])
    tools_registry.register_skills_store(skills_store)

    memory_store = AgentCore::Resources::Memory::InMemory.new
    tools_registry.register_memory_store(memory_store)

    policy = Cybros::AgentRuntimeResolver.phase_0_tool_policy(base_tool_policy: AgentCore::Resources::Tools::Policy::ConfirmAll.new)

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)

    allowed_mem = policy.authorize(name: "memory_search", arguments: { "query" => "x", "limit" => 1 }, context: ctx)
    assert_equal :allow, allowed_mem.outcome

    allowed_skills = policy.authorize(name: "skills_list", arguments: {}, context: ctx)
    assert_equal :allow, allowed_skills.outcome

    confirmed = policy.authorize(name: "subagent_spawn", arguments: {}, context: ctx)
    assert_equal :confirm, confirmed.outcome
  end
end

