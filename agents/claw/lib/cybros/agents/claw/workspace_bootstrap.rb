require "fileutils"

module Cybros
  module Agents
    module Claw
      class WorkspaceBootstrap
        BOOTSTRAP_FILES = {
          "prompts/AGENT.md" => "AGENTS.md",
          "prompts/SOUL.md" => "SOUL.md",
          "prompts/USER.md" => "USER.md",
        }.freeze

        def self.seed!(source_root:, destination_root:)
          new(source_root:, destination_root:).seed!
        end

        def initialize(source_root:, destination_root:)
          @source_root = Pathname.new(source_root.to_s).expand_path
          @destination_root = Pathname.new(destination_root.to_s).expand_path
        end

        def seed!
          destination_root.mkpath

          BOOTSTRAP_FILES.each do |relative_source, destination_name|
            seed_file(relative_source:, destination_name:)
          end

          seed_memory_files!
          seed_skills!

          destination_root
        end

        private

        attr_reader :source_root, :destination_root

        def seed_file(relative_source:, destination_name:)
          destination_path = destination_root.join(destination_name)
          return if destination_path.exist?

          destination_path.write(source_root.join(relative_source).read)
        end

        def seed_memory_files!
          memory_file = destination_root.join("MEMORY.md")
          memory_file.write("") unless memory_file.exist?
          destination_root.join("memory").mkpath
          today_log = destination_root.join(DailyMemoryTarget.call)
          today_log.dirname.mkpath
          today_log.write("") unless today_log.exist?
        end

        def seed_skills!
          source_skills_root = source_root.join("skills")
          return unless source_skills_root.directory?

          destination_skills_root = destination_root.join("skills")
          source_skills_root.children.each do |child|
            destination_path = destination_skills_root.join(child.basename)
            next if destination_path.exist?

            destination_skills_root.mkpath
            FileUtils.cp_r(child, destination_path, preserve: true)
          end
        end
      end
    end
  end
end
