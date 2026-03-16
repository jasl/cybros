require "digest"
require "find"
require "json"
require "pathname"

module Agents
  module SkillInstallation
    class Manifest
      INVALID_SKILL_ENTRY_CODE = "cybros.skills_install.invalid_skill_entry".freeze

      def self.build(skill_root:)
        new(skill_root:).build
      end

      def initialize(skill_root:)
        @skill_root = Pathname.new(skill_root).expand_path
      end

      def build
        files = []

        Find.find(@skill_root.to_s) do |path|
          current = Pathname.new(path)
          next if current == @skill_root

          stat = File.lstat(path)
          relative_path = current.relative_path_from(@skill_root).to_s.tr(File::SEPARATOR, "/")

          if stat.symlink?
            raise_invalid_entry!("Skill packages may not contain symlinks.", relative_path:)
          elsif stat.directory?
            next
          elsif !stat.file?
            raise_invalid_entry!("Skill packages may only contain regular files.", relative_path:)
          end

          bytes = File.binread(path)
          files << {
            path: relative_path,
            byte_size: bytes.bytesize,
            sha256: Digest::SHA256.hexdigest(bytes),
          }
        end

        package_sha256 = Digest::SHA256.hexdigest(JSON.generate(files.sort_by { |entry| entry.fetch(:path) }))

        {
          files: files.sort_by { |entry| entry.fetch(:path) },
          package_sha256: package_sha256,
        }
      end

      private

        def raise_invalid_entry!(message, relative_path:)
          AgentCore::ValidationError.raise!(
            message,
            code: INVALID_SKILL_ENTRY_CODE,
            details: {
              path: relative_path,
            },
          )
        end
    end
  end
end
