require "test_helper"
require "tmpdir"

class Agents::SkillsStoreBuilderTest < ActiveSupport::TestCase
  test "build merges platform and agent-local skills into a snapshotted store" do
    Dir.mktmpdir("cybros-platform-skills-") do |platform_skills_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        write_skill!(platform_skills_root, name: "platform-skill", description: "Platform description")

        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Skills builder")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "agent-skill", description: "Agent description")

          store =
            Agents::SkillsStoreBuilder.build(
              agent: conversation.agent,
              platform_skill_dirs: [platform_skills_root],
            )

          assert_equal %w[agent-skill platform-skill self-mutate], store.list_skills.map(&:name)

          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "agent-skill", description: "Updated description")

          assert_equal "Agent description", store.list_skills.find { |meta| meta.name == "agent-skill" }.description

          refreshed_store =
            Agents::SkillsStoreBuilder.build(
              agent: conversation.agent,
              platform_skill_dirs: [platform_skills_root],
            )

          assert_equal "Updated description", refreshed_store.list_skills.find { |meta| meta.name == "agent-skill" }.description
        end
      end
    end
  end

  test "build fails closed when agent-local skills collide with platform skills" do
    Dir.mktmpdir("cybros-platform-skills-") do |platform_skills_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        write_skill!(platform_skills_root, name: "shared-skill", description: "Platform description")

        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Skills collision")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "shared-skill", description: "Agent description")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillsStoreBuilder.build(
                agent: conversation.agent,
                platform_skill_dirs: [platform_skills_root],
              )
            end

          assert_equal "cybros.agent_runtime.skills_name_collision", error.code
          assert_equal "shared-skill", error.details[:skill_name]
        end
      end
    end
  end

  test "configured catalog skills are discoverable but do not participate in runtime precedence" do
    Dir.mktmpdir("cybros-platform-skills-") do |platform_skills_root|
      Dir.mktmpdir("cybros-catalog-skills-") do |catalog_root|
        Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
          write_skill!(platform_skills_root, name: "platform-skill", description: "Platform description")
          write_skill!(catalog_root, name: "catalog-skill", description: "Catalog description")

          with_default_agent_workspace_root(workspace_root) do
            conversation = create_conversation!(title: "Catalog layering")
            write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "agent-skill", description: "Agent description")

            catalog_entries =
              with_skill_catalog_sources(
                [
                  {
                    "catalog" => "curated",
                    "root" => catalog_root,
                  },
                ],
              ) do
                Agents::SkillCatalog.list(agent: conversation.agent)
              end

            assert_equal ["catalog-skill"], catalog_entries.map { |entry| entry.fetch(:name) }

            store =
              Agents::SkillsStoreBuilder.build(
                agent: conversation.agent,
                platform_skill_dirs: [platform_skills_root],
              )

            assert_equal %w[agent-skill platform-skill self-mutate].sort, store.list_skills.map(&:name).sort
            refute_includes store.list_skills.map(&:name), "catalog-skill"
          end
        end
      end
    end
  end

  test "build clears the installer dirty marker after the next top-level store rebuild" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Dirty marker")
          skill_root = write_staged_skill!(stage_root, name: "fresh-skill", description: "Fresh description")

          Agents::SkillInstallationService.install(
            agent: conversation.agent,
            source_kind: "github",
            repo: "openai/skills",
            ref: "main",
            path: "skills/fresh-skill",
            source_fetcher: stub_fetcher(stage_root:, skill_root:),
          )

          assert_predicate Agents::SkillsStoreBuilder.dirty_marker_path_for(agent: conversation.agent), :exist?

          store = Agents::SkillsStoreBuilder.build(agent: conversation.agent, platform_skill_dirs: [])

          assert_includes store.list_skills.map(&:name), "fresh-skill"
          refute_predicate Agents::SkillsStoreBuilder.dirty_marker_path_for(agent: conversation.agent), :exist?
        end
      end
    end
  end

  test "default platform skill dirs expose the system skill installer without seeding it into agent-local skills" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "System skill installer")

        store = Agents::SkillsStoreBuilder.build(agent: conversation.agent)

        assert_includes store.list_skills.map(&:name), "skill-installer"
        refute_predicate conversation.agent.workspace_root_path.join("skills/skill-installer"), :exist?
      end
    end
  end

  private

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

    def write_staged_skill!(stage_root, name:, description:)
      skill_root = Pathname.new(stage_root).join(name)
      FileUtils.mkdir_p(skill_root)
      File.write(
        skill_root.join("SKILL.md"),
        <<~MD,
          ---
          name: #{name}
          description: #{description}
          ---

          # #{name}
        MD
      )
      skill_root
    end

    def stub_fetcher(stage_root:, skill_root:)
      Class.new do
        define_method(:fetch!) do |**|
          {
            stage_root: stage_root,
            skill_root: skill_root,
          }
        end
      end.new
    end

    def with_skill_catalog_sources(sources)
      singleton = RuntimeSetting.singleton_class
      original_method = singleton.instance_method(:skill_catalog_sources)
      singleton.send(:define_method, :skill_catalog_sources) { sources }
      yield
    ensure
      singleton.send(:define_method, :skill_catalog_sources, original_method)
    end
end
