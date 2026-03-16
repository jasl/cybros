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
end
