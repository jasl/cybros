require "set"

module Cybros
  module Agents
    module Claw
      class SkillCatalog
        def self.list(workspace_root:, sources: RuntimeSettings.skill_catalog_sources)
          new(workspace_root:, sources:).list
        end

        def initialize(workspace_root:, sources:)
          @workspace_root = Pathname.new(workspace_root.to_s).expand_path
          @sources = Array(sources)
        end

        def list
          @sources.flat_map do |source|
            root = Pathname.new(source.fetch("root")).expand_path
            next [] unless root.directory?

            SkillsStore.new(dirs: [root.to_s], strict: true).list_skills.map do |meta|
              {
                "catalog" => source.fetch("catalog"),
                "name" => meta.name,
                "description" => meta.description,
                "path" => meta.name,
                "installed" => installed_skill_names.include?(meta.name),
              }
            end
          end.sort_by { |entry| [entry.fetch("catalog"), entry.fetch("name")] }
        end

        private

        def installed_skill_names
          @installed_skill_names ||=
            if (skills_dir = @workspace_root.join("skills")).directory?
              SkillsStore.new(dirs: [skills_dir.to_s], strict: true).list_skills.map(&:name).to_set
            else
              Set.new
            end
        end
      end
    end
  end
end
