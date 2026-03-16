require "set"

module Agents
  class SkillCatalog
    def self.list(agent:, sources: nil)
      new(agent:, sources:).list
    end

    def initialize(agent:, sources:)
      @agent = agent
      @sources = sources.nil? ? RuntimeSetting.skill_catalog_sources : Array(sources)
    end

    def list
      @sources.flat_map do |source|
        root = Pathname.new(source.fetch("root")).expand_path
        next [] unless root.directory?

        store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: [root.to_s], strict: true)

        store.list_skills.map do |meta|
          {
            catalog: source.fetch("catalog"),
            name: meta.name,
            description: meta.description,
            path: meta.name,
            installed: installed_skill_names.include?(meta.name),
          }
        end
      end.sort_by { |entry| [entry.fetch(:catalog).to_s, entry.fetch(:name).to_s] }
    end

    private

      def installed_skill_names
        @installed_skill_names ||=
          if (skills_dir = @agent&.workspace_root_path&.join("skills"))&.directory?
            AgentCore::Resources::Skills::FileSystemStore.new(dirs: [skills_dir.to_s], strict: true)
              .list_skills
              .map(&:name)
              .to_set
          else
            Set.new
          end
      end
  end
end
