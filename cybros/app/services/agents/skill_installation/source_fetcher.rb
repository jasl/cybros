require "fileutils"
require "open3"
require "pathname"
require "tmpdir"
require "uri"

module Agents
  module SkillInstallation
    class SourceFetcher
      FETCH_FAILED_CODE = "cybros.skills_install.fetch_failed".freeze
      UNKNOWN_SOURCE_KIND_CODE = "cybros.skills_install.unknown_source_kind".freeze

      def self.normalize_github_repo(repo)
        raw = repo.to_s.strip
        return raw if raw.blank?
        return raw if raw.start_with?("file://")
        return raw if Pathname.new(raw).exist?

        uri = URI.parse(raw)
        return raw unless uri.is_a?(URI::HTTP) && uri.host.to_s.casecmp("github.com").zero?

        segments = uri.path.to_s.split("/").reject(&:blank?)
        return raw unless segments.length == 2

        "#{segments.first}/#{segments.last.delete_suffix(".git")}"
      rescue URI::InvalidURIError
        raw
      end

      def initialize(catalog_sources: RuntimeSetting.skill_catalog_sources)
        @catalog_sources = Array(catalog_sources)
      end

      def fetch!(source_kind:, catalog: nil, catalog_entry: nil, repo: nil, ref: nil, path: nil)
        case source_kind.to_s
        when "catalog"
          fetch_catalog!(catalog:, catalog_entry:)
        when "github"
          fetch_github!(repo:, ref:, path:)
        else
          AgentCore::ValidationError.raise!(
            "Unknown skill source kind.",
            code: UNKNOWN_SOURCE_KIND_CODE,
            details: { source_kind: source_kind.to_s },
          )
        end
      end

      private

        def fetch_catalog!(catalog:, catalog_entry:)
          source = @catalog_sources.find { |entry| entry.is_a?(Hash) && entry["catalog"].to_s == catalog.to_s }
          stage_root = Pathname.new(Dir.mktmpdir("cybros-skill-stage-"))
          source_root = Pathname.new(source.fetch("root")).expand_path
          source_skill_root = source_root.join(catalog_entry.to_s)
          staged_skill_root = stage_root.join(source_skill_root.basename)

          FileUtils.cp_r(source_skill_root, staged_skill_root, preserve: true)

          {
            stage_root: stage_root.to_s,
            skill_root: staged_skill_root.to_s,
          }
        rescue StandardError => e
          raise_fetch_failure!(e, source_kind: "catalog", catalog: catalog, catalog_entry: catalog_entry)
        end

        def fetch_github!(repo:, ref:, path:)
          normalized_repo = self.class.normalize_github_repo(repo)
          stage_root = Pathname.new(Dir.mktmpdir("cybros-skill-stage-"))
          stage_source_root = stage_root.join("source")

          if local_repo_path?(normalized_repo)
            copy_local_source!(repo: normalized_repo, destination: stage_source_root)
          else
            fetch_github_with_git!(repo: normalized_repo, ref:, destination: stage_source_root, path:)
          end

          skill_root = path.to_s.strip.present? ? stage_source_root.join(path.to_s) : stage_source_root

          {
            stage_root: stage_root.to_s,
            skill_root: skill_root.to_s,
            repo: normalized_repo,
          }
        rescue StandardError => e
          raise_fetch_failure!(e, source_kind: "github", repo: normalized_repo || repo, ref: ref, path: path)
        end

        def copy_local_source!(repo:, destination:)
          source_root =
            if repo.to_s.start_with?("file://")
              Pathname.new(repo.to_s.delete_prefix("file://")).expand_path
            else
              Pathname.new(repo.to_s).expand_path
            end

          FileUtils.mkdir_p(destination.dirname)
          FileUtils.cp_r(source_root, destination, preserve: true)
        end

        def fetch_github_with_git!(repo:, ref:, destination:, path:)
          remote = "https://github.com/#{repo}.git"
          clone_command = ["clone", "--filter=blob:none"]
          clone_command << "--sparse" if path.to_s.strip.present?
          clone_command.concat([remote, destination.to_s])
          run_git!(*clone_command)
          run_git!("-C", destination.to_s, "checkout", ref.to_s) if ref.to_s.strip.present?
          if path.to_s.strip.present?
            run_git!("-C", destination.to_s, "sparse-checkout", "set", "--no-cone", path.to_s)
          end
        end

        def run_git!(*command)
          stdout, stderr, status = Open3.capture3("git", *command)
          return stdout if status.success?

          raise "#{stderr.presence || stdout.presence || "git command failed"}"
        end

        def local_repo_path?(repo)
          raw = repo.to_s.strip
          return false if raw.blank?

          if raw.start_with?("file://")
            Pathname.new(raw.delete_prefix("file://")).exist?
          else
            Pathname.new(raw).exist?
          end
        end

        def raise_fetch_failure!(error, **details)
          AgentCore::ValidationError.raise!(
            "Failed to fetch skill source.",
            code: FETCH_FAILED_CODE,
            details: details.merge(error_class: error.class.name),
          )
        end
    end
  end
end
