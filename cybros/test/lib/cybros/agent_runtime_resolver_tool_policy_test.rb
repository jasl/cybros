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

  test "skills_install always requires confirmation while skills_catalog_list remains readable" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "Skill installer policy", metadata: { "agent" => {} })
        node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
        runtime = build_runtime(node: node)
        context = runtime_execution_context(runtime)

        catalog_list =
          runtime.tool_policy.authorize(
            name: "skills_catalog_list",
            arguments: { "catalog" => "curated" },
            context: context,
          )
        install =
          runtime.tool_policy.authorize(
            name: "skills_install",
            arguments: {
              "source_kind" => "github",
              "repo" => "https://github.com/openai/skills",
            },
            context: context,
          )

        assert_equal :allow, catalog_list.outcome
        assert_equal :confirm, install.outcome
      end
    end
  end

  test "skills_install surfaces platform collisions through the runtime tools registry" do
    Dir.mktmpdir("cybros-platform-skills-") do |platform_skills_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        write_skill!(platform_skills_root, name: "platform-skill", description: "Platform description")

        with_default_agent_workspace_root(workspace_root) do
          with_platform_skill_dirs([platform_skills_root]) do
            conversation = create_conversation!(title: "Skill install collision", metadata: { "agent" => {} })
            node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
            runtime = build_runtime(node: node)
            context = runtime_execution_context(runtime)

            result =
              runtime.tools_registry.execute(
                name: "skills_install",
                arguments: {
                  "source_kind" => "github",
                  "repo" => "openai/skills",
                  "path" => "skills/example-skill",
                  "install_as" => "platform-skill",
                },
                context: context,
              )

            assert_equal true, result.error
            assert_equal "cybros.skills_install.destination_conflicts_with_platform_skill", result.metadata.dig("validation_error", "code")
          end
        end
      end
    end
  end

  test "skills installed mid-turn become visible on the next runtime build and clear the dirty marker" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-local-skill-repo-") do |repo_root|
        skill_dir = Pathname.new(repo_root).join("skills/fresh-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(
          skill_dir.join("SKILL.md"),
          <<~MD,
            ---
            name: fresh-skill
            description: Fresh description
            ---

            # fresh-skill
          MD
        )

        with_default_agent_workspace_root(workspace_root) do
          first_conversation = create_conversation!(title: "First turn", metadata: { "agent" => {} })
          second_conversation = create_conversation!(title: "Second turn", metadata: { "agent" => {} }, agent: first_conversation.agent)

          first_node = first_conversation.append_user_message!(content: "Hello").fetch(:agent_node)
          first_runtime = build_runtime(node: first_node)
          context = runtime_execution_context(first_runtime)

          install_result =
            first_runtime.tools_registry.execute(
              name: "skills_install",
              arguments: {
                "source_kind" => "github",
                "repo" => repo_root,
                "path" => "skills/fresh-skill",
              },
              context: context,
            )
          refute install_result.error

          payload = JSON.parse(install_result.text)
          assert_equal "single_skill", payload.fetch("mode")
          assert_equal 1, payload.fetch("installed_count")
          assert_equal true, payload.fetch("refresh_effective_on_next_top_level_turn")
          assert_equal "skills/fresh-skill", payload.fetch("installed_skills").first.fetch("source_path")
          assert_equal "fresh-skill", payload.fetch("installed_skills").first.fetch("installed_name")

          first_payload = JSON.parse(first_runtime.tools_registry.execute(name: "skills_list", arguments: {}).text)
          refute_includes first_payload.fetch("skills").map { |skill| skill.fetch("name") }, "fresh-skill"
          assert_predicate Agents::SkillsStoreBuilder.dirty_marker_path_for(agent: first_conversation.agent), :exist?

          second_node = second_conversation.append_user_message!(content: "Hello again").fetch(:agent_node)
          second_runtime = build_runtime(node: second_node)
          second_payload = JSON.parse(second_runtime.tools_registry.execute(name: "skills_list", arguments: {}).text)

          assert_includes second_payload.fetch("skills").map { |skill| skill.fetch("name") }, "fresh-skill"
          refute_predicate Agents::SkillsStoreBuilder.dirty_marker_path_for(agent: first_conversation.agent), :exist?
        end
      end
    end
  end

  test "runtime returns compact repo-root skills_install payloads without long local paths" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-local-skill-repo-") do |repo_root|
        write_skill!(Pathname.new(repo_root).join("skills"), name: "alpha-skill", description: "Alpha description")
        write_skill!(Pathname.new(repo_root).join("skills"), name: "beta-skill", description: "Beta description")

        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Compact install payload", metadata: { "agent" => {} })
          node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
          runtime = build_runtime(node: node)
          context = runtime_execution_context(runtime)

          install_result =
            runtime.tools_registry.execute(
              name: "skills_install",
              arguments: {
                "source_kind" => "github",
                "repo" => repo_root,
              },
              context: context,
            )
          refute install_result.error

          payload = JSON.parse(install_result.text)
          assert_equal "repo_root_batch", payload.fetch("mode")
          assert_equal 2, payload.fetch("installed_count")
          payload.fetch("installed_skills").each do |entry|
            refute entry.key?("live_path")
            refute entry.key?("provenance_path")
            refute entry.key?("snapshot_path")
          end
        end
      end
    end
  end

  test "runtime exposes the system skill installer with installer-specific guidance while leaving agent-local skills separate" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "System skill installer", metadata: { "agent" => {} })
        node = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
        runtime = build_runtime(node: node)

        assert_includes runtime.skills_store.list_skills.map(&:name), "skill-installer"
        refute_predicate conversation.agent.workspace_root_path.join("skills/skill-installer"), :exist?

        payload = JSON.parse(runtime.tools_registry.execute(name: "skills_load", arguments: { "name" => "skill-installer" }).text)

        assert_includes payload.fetch("body_markdown"), "Use `skills_catalog_list` to discover installable skills"
        assert_includes payload.fetch("body_markdown"), "Do not fetch upstream skill files and reconstruct them with `write`, `edit`, or `apply_patch`."
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
