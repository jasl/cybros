require "test_helper"
require "json"
require "tmpdir"

class Cybros::AgentOwnedToolsTest < ActiveSupport::TestCase
  test "memory tools expose scoped workspace-memory parameters on the public tool surface" do
    tools = Cybros::AgentOwnedTools.build.index_by(&:name)

    search_schema = tools.fetch("memory_search").parameters
    get_schema = tools.fetch("memory_get").parameters
    store_schema = tools.fetch("memory_store").parameters

    assert_equal "Search scoped workspace memory files and return matching lines.", tools.fetch("memory_search").description
    assert_equal "Read a scoped workspace memory document.", tools.fetch("memory_get").description
    assert_equal "Store durable notes in a scoped workspace memory document.", tools.fetch("memory_store").description

    assert_equal %w[query], search_schema.fetch(:required)
    assert_includes search_schema.fetch(:properties).keys, :scopes
    assert_equal %w[root conversation lane], search_schema.dig(:properties, :scopes, :items, :enum)

    assert_includes get_schema.fetch(:properties).keys, :scope
    assert_equal %w[root conversation lane], get_schema.dig(:properties, :scope, :enum)
    assert_includes get_schema.fetch(:properties).keys, :target

    assert_equal %w[content], store_schema.fetch(:required)
    assert_includes store_schema.fetch(:properties).keys, :scope
    assert_equal %w[root conversation lane], store_schema.dig(:properties, :scope, :enum)
    assert_includes store_schema.fetch(:properties).keys, :target
    assert_equal %w[append replace], store_schema.dig(:properties, :mode, :enum)
  end

  test "skill installer tools are exposed on the public tool surface" do
    tools = Cybros::AgentOwnedTools.build.index_by(&:name)

    catalog_schema = tools.fetch("skills_catalog_list").parameters
    install_schema = tools.fetch("skills_install").parameters

    assert_equal "List installable skills from configured catalogs.", tools.fetch("skills_catalog_list").description
    assert_equal "Install or replace agent-local skills from a catalog entry, GitHub skill path, or GitHub repo root batch.", tools.fetch("skills_install").description

    assert_includes catalog_schema.fetch(:properties).keys, :catalog
    assert_includes catalog_schema.fetch(:properties).keys, :path
    assert_includes catalog_schema.fetch(:properties).keys, :query

    assert_equal %w[source_kind], install_schema.fetch(:required)
    assert_equal %w[catalog github], install_schema.dig(:properties, :source_kind, :enum)
    assert_includes install_schema.fetch(:properties).keys, :catalog
    assert_includes install_schema.fetch(:properties).keys, :catalog_entry
    assert_includes install_schema.fetch(:properties).keys, :repo
    assert_includes install_schema.fetch(:properties).keys, :ref
    assert_includes install_schema.fetch(:properties).keys, :path
    assert_includes install_schema.fetch(:properties).keys, :install_as
    assert_includes install_schema.fetch(:properties).keys, :replace
    assert_includes install_schema.fetch(:properties).keys, :expected_sha256
    assert_match(/GitHub repo root/i, tools.fetch("skills_install").description)
  end

  test "skills_catalog_list executes against configured catalogs and annotates installed skills" do
    Dir.mktmpdir("cybros-catalog-") do |catalog_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        write_skill!(catalog_root, name: "catalog-skill", description: "Catalog description")
        write_skill!(catalog_root, name: "other-skill", description: "Other description")

        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Catalog tool")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "catalog-skill", description: "Installed local copy")

          tool = Cybros::AgentOwnedTools.build.index_by(&:name).fetch("skills_catalog_list")
          context =
            AgentCore::ExecutionContext.new(
              attributes: {
                agent: { id: conversation.agent.id },
              },
              instrumenter: AgentCore::Observability::NullInstrumenter.new,
            )

          payload =
            with_skill_catalog_sources([{ "catalog" => "curated", "root" => catalog_root }]) do
              JSON.parse(tool.call({ "catalog" => "curated" }, context: context).text)
            end

          assert_equal %w[catalog-skill other-skill], payload.fetch("entries").map { |entry| entry.fetch("name") }
          assert_equal true, payload.fetch("entries").find { |entry| entry.fetch("name") == "catalog-skill" }.fetch("installed")
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
