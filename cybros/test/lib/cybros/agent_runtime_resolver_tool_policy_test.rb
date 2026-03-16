require "test_helper"
require "json"
require "tmpdir"

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

  test "runtime_for registers merged platform and agent-local skills on the live runtime surface" do
    Dir.mktmpdir("cybros-platform-skills-") do |platform_skills_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        write_skill!(platform_skills_root, name: "platform-skill", description: "Platform description")

        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Runtime skills", metadata: { "agent" => {} })
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "agent-skill", description: "Agent description")

          node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)

          with_platform_skill_dirs([platform_skills_root]) do
            runtime =
              Cybros::AgentRuntimeResolver.runtime_for(
                node: node,
                provider: Struct.new(:name).new("stub"),
                base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
                instrumenter: AgentCore::Observability::NullInstrumenter.new,
              )

            assert runtime.tools_registry.include?("skills_list")
            assert runtime.tools_registry.include?("skills_load")
            assert runtime.tools_registry.include?("skills_read_file")
            assert_equal %w[agent-skill platform-skill self-mutate].sort, runtime.skills_store.list_skills.map(&:name).sort

            payload = JSON.parse(runtime.tools_registry.execute(name: "skills_list", arguments: {}).text)
            assert_equal %w[agent-skill platform-skill self-mutate].sort, payload.fetch("skills").map { |skill| skill.fetch("name") }.sort
          end
        end
      end
    end
  end

  test "agent-local skill edits become visible on the next runtime build, not mid-turn" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        first_conversation = create_conversation!(title: "First turn", metadata: { "agent" => {} })
        second_conversation = create_conversation!(title: "Second turn", metadata: { "agent" => {} }, agent: first_conversation.agent)
        write_skill!(first_conversation.agent.workspace_root_path.join("skills"), name: "agent-skill", description: "Before refresh")

        first_node = first_conversation.append_user_message!(content: "Hello").fetch(:agent_node)
        first_runtime =
          Cybros::AgentRuntimeResolver.runtime_for(
            node: first_node,
            provider: Struct.new(:name).new("stub"),
            base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
            instrumenter: AgentCore::Observability::NullInstrumenter.new,
          )

        write_skill!(first_conversation.agent.workspace_root_path.join("skills"), name: "agent-skill", description: "After refresh")

        first_payload = JSON.parse(first_runtime.tools_registry.execute(name: "skills_list", arguments: {}).text)
        first_skill = first_payload.fetch("skills").find { |skill| skill.fetch("name") == "agent-skill" }
        assert_equal "Before refresh", first_skill.fetch("description")

        second_node = second_conversation.append_user_message!(content: "Hello again").fetch(:agent_node)
        second_runtime =
          Cybros::AgentRuntimeResolver.runtime_for(
            node: second_node,
            provider: Struct.new(:name).new("stub"),
            base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
              instrumenter: AgentCore::Observability::NullInstrumenter.new,
          )

        second_payload = JSON.parse(second_runtime.tools_registry.execute(name: "skills_list", arguments: {}).text)
        second_skill = second_payload.fetch("skills").find { |skill| skill.fetch("name") == "agent-skill" }
        assert_equal "After refresh", second_skill.fetch("description")
      end
    end
  end

  test "protected agent-root writes still require confirmation under an allow-all base policy" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "Protected writes", metadata: { "agent" => {} })
        node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
        runtime = build_runtime(node: node)
        context = runtime_execution_context(runtime)

        regular_write =
          runtime.tool_policy.authorize(
            name: "write",
            arguments: { "path" => "notes/todo.txt", "content" => "workspace" },
            context: context,
          )
        soul_write =
          runtime.tool_policy.authorize(
            name: "write",
            arguments: { "path" => "../../SOUL.md", "content" => "mutated soul" },
            context: context,
          )
        user_write =
          runtime.tool_policy.authorize(
            name: "write",
            arguments: { "path" => "../../USER.md", "content" => "mutated user" },
            context: context,
          )
        skill_write =
          runtime.tool_policy.authorize(
            name: "write",
            arguments: { "path" => "../../skills/self-mutate/SKILL.md", "content" => "# rewritten" },
            context: context,
          )
        skill_patch =
          runtime.tool_policy.authorize(
            name: "apply_patch",
            arguments: {
              "patch" => <<~PATCH,
                *** Begin Patch
                *** Update File: ../../skills/self-mutate/SKILL.md
                @@
                -old
                +new
                *** End Patch
              PATCH
            },
            context: context,
          )

        assert_equal :allow, regular_write.outcome
        assert_equal :confirm, soul_write.outcome
        assert_equal :confirm, user_write.outcome
        assert_equal :confirm, skill_write.outcome
        assert_equal :confirm, skill_patch.outcome
      end
    end
  end

  test "protected agent-root paths deny AGENTS history writes and exec mutation attempts" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "Protected denies", metadata: { "agent" => {} })
        node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
        runtime = build_runtime(node: node)
        context = runtime_execution_context(runtime)

        agents_write =
          runtime.tool_policy.authorize(
            name: "write",
            arguments: { "path" => "../../AGENTS.md", "content" => "hijack" },
            context: context,
          )
        history_write =
          runtime.tool_policy.authorize(
            name: "write",
            arguments: { "path" => "../../.history/SOUL.md", "content" => "scratch" },
            context: context,
          )
        exec_mutation =
          runtime.tool_policy.authorize(
            name: "exec",
            arguments: { "command" => "printf hacked > ../../SOUL.md" },
            context: context,
          )
        exec_read_only =
          runtime.tool_policy.authorize(
            name: "exec",
            arguments: { "command" => "cat ../../SOUL.md" },
            context: context,
          )

        assert_equal :deny, agents_write.outcome
        assert_equal :deny, history_write.outcome
        assert_equal :deny, exec_mutation.outcome
        assert_equal :allow, exec_read_only.outcome
      end
    end
  end

  test "compact_context becomes visible when context pressure escalates to enqueue_compact" do
    conversation = create_conversation!(metadata: { "agent" => { "agent_profile" => "coding" } })
    node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
    runtime = build_runtime(node: node)
    context =
      AgentCore::ExecutionContext.new(
        attributes: runtime.execution_context_attributes.deep_merge(
          context_budget: {
            budget_action: "enqueue_compact",
          },
        ),
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    visible_tools = runtime.tool_policy.filter(tools: runtime.tools_registry.definitions(format: :generic), context: context)

    assert_includes visible_tools.map { |tool| tool[:name] || tool["name"] }, "compact_context"
  end

  private

    def build_runtime(node:)
      Cybros::AgentRuntimeResolver.runtime_for(
        node: node,
        provider: Struct.new(:name).new("stub"),
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    end

    def runtime_execution_context(runtime)
      AgentCore::ExecutionContext.new(
        attributes: runtime.execution_context_attributes,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    end

    def write_skill!(root, name:, description:)
      skill_dir = Pathname.new(root).join(name)
      FileUtils.mkdir_p(skill_dir)
      File.write(
        skill_dir.join("SKILL.md"),
        <<~MD,
          ---
          name: #{name}
          description: #{description}
          ---

          # #{name}
        MD
      )
    end

    def with_platform_skill_dirs(dirs)
      singleton = Agents::SkillsStoreBuilder.singleton_class
      original_method = singleton.instance_method(:default_platform_skill_dirs)
      singleton.send(:define_method, :default_platform_skill_dirs) { dirs }
      yield
    ensure
      singleton.send(:define_method, :default_platform_skill_dirs, original_method)
    end
end
