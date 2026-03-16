require "test_helper"
require "tmpdir"

class Agents::SkillCatalogTest < ActiveSupport::TestCase
  test "list returns discoverable catalog entries with installed annotations" do
    Dir.mktmpdir("cybros-skill-catalog-") do |catalog_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        write_skill!(catalog_root, name: "catalog-skill", description: "Catalog description")
        write_skill!(catalog_root, name: "other-skill", description: "Other description")

        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Catalog")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "catalog-skill", description: "Installed local copy")

          entries =
            Agents::SkillCatalog.list(
              agent: conversation.agent,
              sources: [
                {
                  "catalog" => "curated",
                  "root" => catalog_root,
                },
              ],
            )

          assert_equal %w[catalog-skill other-skill], entries.map { |entry| entry.fetch(:name) }

          installed = entries.find { |entry| entry.fetch(:name) == "catalog-skill" }
          refute_nil installed
          assert_equal "curated", installed.fetch(:catalog)
          assert_equal true, installed.fetch(:installed)

          pending = entries.find { |entry| entry.fetch(:name) == "other-skill" }
          refute_nil pending
          assert_equal false, pending.fetch(:installed)
          assert_equal "Other description", pending.fetch(:description)
        end
      end
    end
  end

  test "list resolves configured catalog sources deterministically when sources are omitted" do
    Dir.mktmpdir("cybros-catalog-a-") do |catalog_a_root|
      Dir.mktmpdir("cybros-catalog-b-") do |catalog_b_root|
        Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
          write_skill!(catalog_b_root, name: "zeta-skill", description: "Zeta description")
          write_skill!(catalog_a_root, name: "alpha-skill", description: "Alpha description")

          with_default_agent_workspace_root(workspace_root) do
            conversation = create_conversation!(title: "Configured catalogs")

            with_skill_catalog_sources(
              [
                { "catalog" => "beta", "root" => catalog_b_root },
                { "catalog" => "alpha", "root" => catalog_a_root },
              ],
            ) do
              entries = Agents::SkillCatalog.list(agent: conversation.agent)

              assert_equal [%w[alpha alpha-skill], %w[beta zeta-skill]], entries.map { |entry| [entry.fetch(:catalog), entry.fetch(:name)] }
            end
          end
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

    def with_skill_catalog_sources(sources)
      singleton = RuntimeSetting.singleton_class
      original_method = singleton.instance_method(:skill_catalog_sources)
      singleton.send(:define_method, :skill_catalog_sources) { sources }
      yield
    ensure
      singleton.send(:define_method, :skill_catalog_sources, original_method)
    end
end
