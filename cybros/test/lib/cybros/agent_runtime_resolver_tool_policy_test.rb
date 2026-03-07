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

  test "subagent runtime keeps memory_* and skills_* behind the worker profile boundary" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "key" => "subagent:worker",
            "agent_profile" => "subagent",
          },
        },
      )

    node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
    runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: node,
        provider: Struct.new(:name).new("stub"),
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)

    denied_mem = runtime.tool_policy.authorize(name: "memory_search", arguments: { "query" => "x", "limit" => 1 }, context: ctx)
    denied_skills = runtime.tool_policy.authorize(name: "skills_list", arguments: {}, context: ctx)
    denied_spawn = runtime.tool_policy.authorize(name: "subagent_spawn", arguments: {}, context: ctx)

    assert_equal :deny, denied_mem.outcome
    assert_equal "tool_not_in_profile", denied_mem.reason
    assert_equal :deny, denied_skills.outcome
    assert_equal "tool_not_in_profile", denied_skills.reason
    assert_equal :deny, denied_spawn.outcome
    assert_equal "tool_not_in_profile", denied_spawn.reason
  end

  test "debug mode does not widen the subagent worker policy boundary" do
    standard_conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "key" => "subagent:worker",
            "agent_profile" => "subagent",
          },
        },
      )
    debug_conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "key" => "subagent:worker",
            "agent_profile" => "subagent",
          },
        },
      )

    standard_node = standard_conversation.append_user_message!(content: "Hello").fetch(:agent_node)
    debug_node = debug_conversation.append_user_message!(content: "Hello", diagnostic_level: "debug").fetch(:agent_node)

    standard_runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: standard_node,
        provider: Struct.new(:name).new("stub"),
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    debug_runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: debug_node,
        provider: Struct.new(:name).new("stub"),
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)

    standard_decision = standard_runtime.tool_policy.authorize(name: "memory_search", arguments: { "query" => "x", "limit" => 1 }, context: ctx)
    debug_decision = debug_runtime.tool_policy.authorize(name: "memory_search", arguments: { "query" => "x", "limit" => 1 }, context: ctx)

    assert_equal :deny, standard_decision.outcome
    assert_equal "tool_not_in_profile", standard_decision.reason
    assert_equal [standard_decision.outcome, standard_decision.reason], [debug_decision.outcome, debug_decision.reason]
  end
end
