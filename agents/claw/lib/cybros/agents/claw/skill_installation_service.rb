require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require "uri"

module Cybros
  module Agents
    module Claw
      class SkillInstallationService
        PLATFORM_COLLISION_CODE = "cybros.skills_install.destination_conflicts_with_platform_skill".freeze
        INVALID_SKILL_ROOT_CODE = "cybros.skills_install.invalid_skill_root".freeze
        INVALID_SKILL_ENTRY_CODE = "cybros.skills_install.invalid_skill_entry".freeze
        SOURCE_HASH_MISMATCH_CODE = "cybros.skills_install.source_hash_mismatch".freeze
        DESTINATION_EXISTS_CODE = "cybros.skills_install.destination_exists".freeze
        INSTALL_AS_NOT_ALLOWED_CODE = "cybros.skills_install.install_as_not_allowed".freeze
        SKILL_NAME_MISMATCH_CODE = "cybros.skills_install.skill_name_mismatch".freeze
        DUPLICATE_INSTALL_NAME_CODE = "cybros.skills_install.duplicate_install_name".freeze
        FETCH_FAILED_CODE = "cybros.skills_install.fetch_failed".freeze
        UNKNOWN_SOURCE_KIND_CODE = "cybros.skills_install.unknown_source_kind".freeze

        def initialize(
          workspace_root:,
          source_kind:,
          catalog: nil,
          catalog_entry: nil,
          repo: nil,
          ref: nil,
          path: nil,
          install_as: nil,
          replace: false,
          expected_sha256: nil,
          catalog_sources: RuntimeSettings.skill_catalog_sources,
          platform_skill_dirs: RuntimeSettings.platform_skill_dirs,
          file_utils: FileUtils
        )
          @workspace_root = Pathname.new(workspace_root.to_s).expand_path
          @source_kind = source_kind.to_s
          @catalog = catalog
          @catalog_entry = catalog_entry
          @repo = repo
          @ref = ref
          @path = path
          @install_as = install_as
          @replace = replace == true
          @expected_sha256 = expected_sha256.to_s.strip.presence
          @catalog_sources = Array(catalog_sources)
          @platform_skill_dirs = Array(platform_skill_dirs)
          @file_utils = file_utils
        end

        def self.install(...)
          new(...).install
        end

        def install
          prepared = prepare
          return install_repo_root_batch(prepared) if prepared.fetch("mode") == "repo_root_batch"

          live_root = @workspace_root.join("skills")
          live_path = live_root.join(prepared.fetch("install_name"))
          temp_path = live_root.join(".install-#{prepared.fetch("install_name")}-#{SecureRandom.hex(4)}")
          backup_root = @workspace_root.join(".state", "skills", "backups")

          @file_utils.mkdir_p(live_root)
          @file_utils.cp_r(prepared.fetch("skill_root"), temp_path, preserve: true)

          snapshot_path = nil
          backup_path = nil

          begin
            if live_path.exist?
              snapshot_path = snapshot_skill!(skill_name: prepared.fetch("install_name"), live_path:)
              @file_utils.mkdir_p(backup_root)
              backup_path = backup_root.join("#{prepared.fetch("install_name")}-#{timestamp_token}")
              @file_utils.mv(live_path, backup_path)
            end

            @file_utils.mv(temp_path, live_path)

            installed_manifest = build_manifest(skill_root: live_path)
            provenance_path =
              write_provenance!(
                skill_name: prepared.fetch("install_name"),
                source_kind: prepared.fetch("source_kind"),
                catalog: prepared["catalog"],
                catalog_entry: prepared["catalog_entry"],
                repo: prepared["repo"],
                ref: prepared["ref"],
                path: prepared["path"],
                source_path: prepared_source_path(prepared),
                source_sha256: prepared.fetch("source_sha256"),
                installed_sha256: installed_manifest.fetch("package_sha256"),
                snapshot_path: snapshot_path,
                install_mode: prepared.fetch("mode"),
                batch_installed_count: 1,
                batch_install_names: [prepared.fetch("install_name")],
              )

            SkillsState.mark_dirty!(workspace_root: @workspace_root)
            @file_utils.rm_rf(backup_path) if backup_path&.exist?

            build_install_result(
              prepared: prepared,
              installed_skills: [
                {
                  "installed_name" => prepared.fetch("install_name"),
                  "source_path" => prepared_source_path(prepared),
                  "live_path" => live_path.to_s,
                  "source_sha256" => prepared.fetch("source_sha256"),
                  "installed_sha256" => installed_manifest.fetch("package_sha256"),
                  "snapshot_path" => snapshot_path,
                  "provenance_path" => provenance_path,
                }.compact,
              ],
            )
          rescue StandardError
            @file_utils.rm_rf(live_path) if live_path.exist? && backup_path&.exist?
            @file_utils.mv(backup_path, live_path) if backup_path&.exist? && !live_path.exist?
            raise
          ensure
            @file_utils.rm_rf(temp_path) if temp_path.exist?
          end
        end

        private

        def prepare
          validate_repo_root_batch_arguments!

          install_name = resolved_install_name
          unless repo_root_batch_mode?
            validate_platform_collision!(install_name)
            validate_destination!(install_name)
          end

          staged = fetch_source!
          stage_root = Pathname.new(staged.fetch("stage_root")).expand_path
          skill_root = Pathname.new(staged.fetch("skill_root")).expand_path
          prepared_repo = staged["repo"].presence || normalized_repo

          if repo_root_batch_mode?
            return {
              "mode" => "repo_root_batch",
              "source_kind" => @source_kind,
              "replace" => @replace,
              "repo" => prepared_repo,
              "ref" => @ref,
              "path" => nil,
              "stage_root" => stage_root.to_s,
              "skill_root" => skill_root.to_s,
              "candidates" => discover_repo_root_candidates!(stage_root:, source_root: skill_root),
            }
          end

          validate_skill_root!(stage_root:, skill_root:)
          manifest = build_manifest(skill_root:)
          validate_expected_sha256!(manifest.fetch("package_sha256"))

          {
            "mode" => "single_skill",
            "source_kind" => @source_kind,
            "install_name" => install_name,
            "replace" => @replace,
            "catalog" => @catalog,
            "catalog_entry" => @catalog_entry,
            "repo" => prepared_repo,
            "ref" => @ref,
            "path" => @path,
            "stage_root" => stage_root.to_s,
            "skill_root" => skill_root.to_s,
            "manifest" => manifest,
            "source_sha256" => manifest.fetch("package_sha256"),
          }
        end

        def fetch_source!
          case @source_kind
          when "catalog"
            fetch_catalog!
          when "github"
            fetch_github!
          else
            ValidationError.raise!(
              "Unknown skill source kind.",
              code: UNKNOWN_SOURCE_KIND_CODE,
              details: { source_kind: @source_kind },
            )
          end
        end

        def fetch_catalog!
          source = @catalog_sources.find { |entry| entry.is_a?(Hash) && entry["catalog"].to_s == @catalog.to_s }
          ValidationError.raise!(
            "Unknown skill catalog.",
            code: FETCH_FAILED_CODE,
            details: { source_kind: "catalog", catalog: @catalog.to_s },
          ) if source.nil?

          stage_root = Pathname.new(Dir.mktmpdir("claw-skill-stage-"))
          source_root = Pathname.new(source.fetch("root")).expand_path
          source_skill_root = source_root.join(@catalog_entry.to_s)
          staged_skill_root = stage_root.join(source_skill_root.basename)

          @file_utils.cp_r(source_skill_root, staged_skill_root, preserve: true)

          {
            "stage_root" => stage_root.to_s,
            "skill_root" => staged_skill_root.to_s,
          }
        rescue ValidationError
          raise
        rescue StandardError => e
          raise_fetch_failure!(e, source_kind: "catalog", catalog: @catalog, catalog_entry: @catalog_entry)
        end

        def fetch_github!
          repo = normalized_repo
          stage_root = Pathname.new(Dir.mktmpdir("claw-skill-stage-"))
          stage_source_root = stage_root.join("source")

          if local_repo_path?(repo)
            copy_local_source!(repo:, destination: stage_source_root)
          else
            fetch_github_with_git!(repo:, ref: @ref, destination: stage_source_root, path: @path)
          end

          skill_root = @path.to_s.strip.present? ? stage_source_root.join(@path.to_s) : stage_source_root

          {
            "stage_root" => stage_root.to_s,
            "skill_root" => skill_root.to_s,
            "repo" => repo,
          }
        rescue ValidationError
          raise
        rescue StandardError => e
          raise_fetch_failure!(e, source_kind: "github", repo: repo || @repo, ref: @ref, path: @path)
        end

        def copy_local_source!(repo:, destination:)
          source_root =
            if repo.to_s.start_with?("file://")
              Pathname.new(repo.delete_prefix("file://")).expand_path
            else
              Pathname.new(repo.to_s).expand_path
            end

          @file_utils.mkdir_p(destination.dirname)
          @file_utils.cp_r(source_root, destination, preserve: true)
        end

        def fetch_github_with_git!(repo:, ref:, destination:, path:)
          remote = "https://github.com/#{repo}.git"
          command = ["clone", "--filter=blob:none"]
          command << "--sparse" if path.to_s.strip.present?
          command.concat([remote, destination.to_s])
          run_git!(*command)
          run_git!("-C", destination.to_s, "checkout", ref.to_s) if ref.to_s.strip.present?
          run_git!("-C", destination.to_s, "sparse-checkout", "set", "--no-cone", path.to_s) if path.to_s.strip.present?
        end

        def run_git!(*command)
          stdout, stderr, status = Open3.capture3("git", *command)
          return stdout if status.success?

          raise(stderr.presence || stdout.presence || "git command failed")
        end

        def raise_fetch_failure!(error, **details)
          ValidationError.raise!(
            "Failed to fetch skill source.",
            code: FETCH_FAILED_CODE,
            details: details.merge(error_class: error.class.name),
          )
        end

        def normalized_repo
          raw = @repo.to_s.strip
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

        def local_repo_path?(repo)
          raw = repo.to_s.strip
          return false if raw.empty?

          if raw.start_with?("file://")
            Pathname.new(raw.delete_prefix("file://")).exist?
          else
            Pathname.new(raw).exist?
          end
        end

        def repo_root_batch_mode?
          @source_kind == "github" && @repo.to_s.strip.present? && @path.to_s.strip.blank?
        end

        def validate_repo_root_batch_arguments!
          return unless repo_root_batch_mode?
          return if @install_as.to_s.strip.blank?

          ValidationError.raise!(
            "Repo-root batch installs do not support install_as.",
            code: INSTALL_AS_NOT_ALLOWED_CODE,
            details: { install_as: @install_as.to_s },
          )
        end

        def resolved_install_name
          explicit = @install_as.to_s.strip
          return explicit if explicit.present?

          case @source_kind
          when "catalog"
            @catalog_entry.to_s.strip
          when "github"
            basename = Pathname.new(@path.to_s).basename.to_s
            basename == "." ? "" : basename
          else
            ""
          end
        end

        def discover_repo_root_candidates!(stage_root:, source_root:)
          validate_staged_directory!(stage_root:, target_root: source_root)

          candidate_roots =
            preferred_repo_root_candidate_roots(source_root).presence ||
              fallback_repo_root_candidate_roots(source_root)

          if candidate_roots.blank?
            ValidationError.raise!(
              "Fetched repository root did not contain any installable skills.",
              code: INVALID_SKILL_ROOT_CODE,
              details: {
                repo: normalized_repo,
                stage_root: stage_root.to_s,
                skill_root: source_root.to_s,
              }.compact,
            )
          end

          candidates = candidate_roots.map { |candidate_root| normalize_repo_root_candidate(stage_root:, source_root:, candidate_root:) }
          validate_repo_root_batch_candidates!(candidates)
          candidates
        end

        def preferred_repo_root_candidate_roots(source_root)
          discover_skill_roots(source_root, patterns: ["skills/*/SKILL.md", "skills/*/*/SKILL.md", "skills/.system/*/SKILL.md"])
        end

        def fallback_repo_root_candidate_roots(source_root)
          discover_skill_roots(source_root, patterns: ["SKILL.md", "*/SKILL.md", "*/*/SKILL.md"])
        end

        def discover_skill_roots(source_root, patterns:)
          Array(patterns).flat_map do |pattern|
            Dir.glob(source_root.join(pattern).to_s)
              .select { |path| File.file?(path) }
              .map { |path| Pathname.new(path).dirname.expand_path }
          end.uniq.sort_by { |root| root.relative_path_from(source_root).to_s.tr(File::SEPARATOR, "/") }
        end

        def normalize_repo_root_candidate(stage_root:, source_root:, candidate_root:)
          validate_skill_root!(stage_root:, skill_root: candidate_root)

          install_name = candidate_root.basename.to_s
          validate_repo_root_candidate_name!(candidate_root:, install_name:)
          manifest = build_manifest(skill_root: candidate_root)

          {
            "install_name" => install_name,
            "source_path" => candidate_root.relative_path_from(source_root).to_s.tr(File::SEPARATOR, "/"),
            "skill_root" => candidate_root.to_s,
            "replace" => @workspace_root.join("skills", install_name).exist? && @replace,
            "manifest" => manifest,
            "source_sha256" => manifest.fetch("package_sha256"),
          }
        end

        def validate_repo_root_candidate_name!(candidate_root:, install_name:)
          frontmatter, = SkillsStore.new(dirs: []).send(:parse_frontmatter, File.read(candidate_root.join("SKILL.md")), expected_name: install_name, path: candidate_root.join("SKILL.md"))
          return if frontmatter.fetch("name") == install_name

          ValidationError.raise!(
            "Repo-root candidate skill names must match their directory names.",
            code: SKILL_NAME_MISMATCH_CODE,
            details: {
              skill_root: candidate_root.to_s,
              install_name: install_name,
              declared_name: frontmatter.fetch("name"),
            },
          )
        rescue ValidationError => e
          raise e unless e.code == "claw.skills.invalid_frontmatter"

          ValidationError.raise!(
            "Repo-root candidate skill names must match their directory names.",
            code: SKILL_NAME_MISMATCH_CODE,
            details: {
              skill_root: candidate_root.to_s,
              install_name: install_name,
            },
          )
        end

        def validate_repo_root_batch_candidates!(candidates)
          duplicates = candidates.group_by { |candidate| candidate.fetch("install_name") }.select { |_name, entries| entries.length > 1 }
          if duplicates.present?
            install_name, entries = duplicates.sort_by { |name, _entries| name }.first
            ValidationError.raise!(
              "Repo-root batch installs may not include duplicate install names.",
              code: DUPLICATE_INSTALL_NAME_CODE,
              details: {
                install_name: install_name,
                source_paths: entries.map { |entry| entry.fetch("source_path") },
              },
            )
          end

          candidates.each do |candidate|
            validate_platform_collision!(candidate.fetch("install_name"))
            validate_destination!(candidate.fetch("install_name"))
          end
        end

        def validate_platform_collision!(install_name)
          return if install_name.blank?
          return unless platform_skill_names.include?(install_name)

          ValidationError.raise!(
            "Installed skills may not override platform skills.",
            code: PLATFORM_COLLISION_CODE,
            details: { skill_name: install_name },
          )
        end

        def validate_destination!(install_name)
          return if install_name.blank? || @replace
          return unless @workspace_root.join("skills", install_name).exist?

          ValidationError.raise!(
            "Destination skill already exists.",
            code: DESTINATION_EXISTS_CODE,
            details: { skill_name: install_name },
          )
        end

        def validate_skill_root!(stage_root:, skill_root:)
          validate_staged_directory!(stage_root:, target_root: skill_root)
          return if skill_root.join("SKILL.md").file?

          ValidationError.raise!(
            "Fetched skill root must contain SKILL.md.",
            code: INVALID_SKILL_ROOT_CODE,
            details: { stage_root: stage_root.to_s, skill_root: skill_root.to_s },
          )
        end

        def validate_staged_directory!(stage_root:, target_root:)
          unless stage_root.directory? && target_root.directory?
            ValidationError.raise!(
              "Fetched skill source did not resolve to a valid directory.",
              code: INVALID_SKILL_ROOT_CODE,
            )
          end

          normalized_stage_root = stage_root.expand_path.to_s
          normalized_target_root = target_root.expand_path.to_s
          unless normalized_target_root == normalized_stage_root || normalized_target_root.start_with?(normalized_stage_root + File::SEPARATOR)
            ValidationError.raise!(
              "Fetched skill path escapes the staged source root.",
              code: INVALID_SKILL_ROOT_CODE,
              details: { stage_root: stage_root.to_s, skill_root: target_root.to_s },
            )
          end
        end

        def validate_expected_sha256!(package_sha256)
          return if @expected_sha256.blank?
          return if ActiveSupport::SecurityUtils.secure_compare(package_sha256, @expected_sha256)

          ValidationError.raise!(
            "Expected source hash did not match the staged source.",
            code: SOURCE_HASH_MISMATCH_CODE,
            details: {
              expected_sha256: @expected_sha256,
              source_sha256: package_sha256,
            },
          )
        end

        def platform_skill_names
          @platform_skill_names ||=
            @platform_skill_dirs.flat_map do |dir|
              root = Pathname.new(dir.to_s)
              next [] unless root.directory?

              SkillsStore.new(dirs: [root.to_s], strict: true).list_skills.map(&:name)
            end
        end

        def build_manifest(skill_root:)
          root = Pathname.new(skill_root).expand_path
          files = []

          Find.find(root.to_s) do |path|
            current = Pathname.new(path)
            next if current == root

            stat = File.lstat(path)
            relative_path = current.relative_path_from(root).to_s.tr(File::SEPARATOR, "/")

            if stat.symlink?
              ValidationError.raise!(
                "Skill packages may not contain symlinks.",
                code: INVALID_SKILL_ENTRY_CODE,
                details: { path: relative_path },
              )
            elsif stat.directory?
              next
            elsif !stat.file?
              ValidationError.raise!(
                "Skill packages may only contain regular files.",
                code: INVALID_SKILL_ENTRY_CODE,
                details: { path: relative_path },
              )
            end

            bytes = File.binread(path)
            files << {
              "path" => relative_path,
              "byte_size" => bytes.bytesize,
              "sha256" => Digest::SHA256.hexdigest(bytes),
            }
          end

          {
            "files" => files.sort_by { |entry| entry.fetch("path") },
            "package_sha256" => Digest::SHA256.hexdigest(JSON.generate(files.sort_by { |entry| entry.fetch("path") })),
          }
        end

        def snapshot_skill!(skill_name:, live_path:)
          snapshot_root = @workspace_root.join(".history", "skills", skill_name, timestamp_token)
          @file_utils.mkdir_p(snapshot_root.dirname)
          @file_utils.cp_r(live_path, snapshot_root, preserve: true)
          snapshot_root.to_s
        end

        def prepared_source_path(prepared)
          prepared["path"].presence || prepared["catalog_entry"].presence || prepared.fetch("install_name")
        end

        def install_repo_root_batch(prepared)
          live_root = @workspace_root.join("skills")
          backup_root = @workspace_root.join(".state", "skills", "backups")
          batch_install_names = prepared.fetch("candidates").map { |candidate| candidate.fetch("install_name") }
          provenance_restore_state = {}

          plans =
            prepared.fetch("candidates").map do |candidate|
              {
                "candidate" => candidate,
                "live_path" => live_root.join(candidate.fetch("install_name")),
                "temp_path" => live_root.join(".install-#{candidate.fetch("install_name")}-#{SecureRandom.hex(4)}"),
                "backup_path" => nil,
                "snapshot_path" => nil,
                "moved_to_backup" => false,
                "promoted" => false,
              }
            end

          @file_utils.mkdir_p(live_root)
          plans.each do |plan|
            @file_utils.cp_r(plan.fetch("candidate").fetch("skill_root"), plan.fetch("temp_path"), preserve: true)
          end

          begin
            plans.each do |plan|
              next unless plan.fetch("live_path").exist?

              plan["snapshot_path"] = snapshot_skill!(skill_name: plan.fetch("candidate").fetch("install_name"), live_path: plan.fetch("live_path"))
              @file_utils.mkdir_p(backup_root)
              plan["backup_path"] = backup_root.join("#{plan.fetch("candidate").fetch("install_name")}-#{timestamp_token}")
              @file_utils.mv(plan.fetch("live_path"), plan.fetch("backup_path"))
              plan["moved_to_backup"] = true
            end

            plans.each do |plan|
              @file_utils.mv(plan.fetch("temp_path"), plan.fetch("live_path"))
              plan["promoted"] = true
            end

            installed_skills =
              plans.map do |plan|
                candidate = plan.fetch("candidate")
                installed_manifest = build_manifest(skill_root: plan.fetch("live_path"))
                restore_key = provenance_path_for(candidate.fetch("install_name"))
                provenance_restore_state[restore_key] = Pathname.new(restore_key).exist? ? File.binread(restore_key) : nil

                provenance_path =
                  write_provenance!(
                    skill_name: candidate.fetch("install_name"),
                    source_kind: prepared.fetch("source_kind"),
                    catalog: prepared["catalog"],
                    catalog_entry: prepared["catalog_entry"],
                    repo: prepared["repo"],
                    ref: prepared["ref"],
                    path: prepared["path"],
                    source_path: candidate.fetch("source_path"),
                    source_sha256: candidate.fetch("source_sha256"),
                    installed_sha256: installed_manifest.fetch("package_sha256"),
                    snapshot_path: plan["snapshot_path"],
                    install_mode: prepared.fetch("mode"),
                    batch_installed_count: plans.length,
                    batch_install_names: batch_install_names,
                  )

                {
                  "installed_name" => candidate.fetch("install_name"),
                  "source_path" => candidate.fetch("source_path"),
                  "live_path" => plan.fetch("live_path").to_s,
                  "source_sha256" => candidate.fetch("source_sha256"),
                  "installed_sha256" => installed_manifest.fetch("package_sha256"),
                  "snapshot_path" => plan["snapshot_path"],
                  "provenance_path" => provenance_path,
                }.compact
              end

            SkillsState.mark_dirty!(workspace_root: @workspace_root)
            plans.each { |plan| @file_utils.rm_rf(plan["backup_path"]) if plan["backup_path"]&.exist? }

            build_install_result(prepared:, installed_skills:)
          rescue StandardError
            plans.each do |plan|
              @file_utils.rm_rf(plan.fetch("live_path")) if plan.fetch("promoted") && plan.fetch("live_path").exist?
              if plan.fetch("moved_to_backup")
                @file_utils.mv(plan.fetch("backup_path"), plan.fetch("live_path")) if plan.fetch("backup_path")&.exist? && !plan.fetch("live_path").exist?
              end
            end
            restore_provenance_state!(provenance_restore_state)
            raise
          ensure
            plans.each { |plan| @file_utils.rm_rf(plan.fetch("temp_path")) if plan.fetch("temp_path").exist? }
          end
        end

        def build_install_result(prepared:, installed_skills:)
          {
            "mode" => prepared.fetch("mode"),
            "source_kind" => prepared.fetch("source_kind"),
            "catalog" => prepared["catalog"],
            "catalog_entry" => prepared["catalog_entry"],
            "repo" => prepared["repo"],
            "ref" => prepared["ref"],
            "refresh_effective_on_next_top_level_turn" => true,
            "installed_count" => installed_skills.length,
            "installed_skills" => installed_skills,
          }.compact
        end

        def write_provenance!(
          skill_name:,
          source_kind:,
          catalog:,
          catalog_entry:,
          repo:,
          ref:,
          path:,
          source_path:,
          source_sha256:,
          installed_sha256:,
          snapshot_path:,
          install_mode:,
          batch_installed_count:,
          batch_install_names:
        )
          provenance_path = Pathname.new(provenance_path_for(skill_name))
          @file_utils.mkdir_p(provenance_path.dirname)
          File.write(
            provenance_path,
            JSON.pretty_generate(
              {
                skill_name: skill_name,
                source_kind: source_kind,
                catalog: catalog,
                catalog_entry: catalog_entry,
                repo: repo,
                ref: ref,
                path: path,
                source_path: source_path,
                source_sha256: source_sha256,
                installed_sha256: installed_sha256,
                installed_at: Time.current.utc.iso8601,
                snapshot_path: snapshot_path,
                install_mode: install_mode,
                batch_installed_count: batch_installed_count,
                batch_install_names: Array(batch_install_names).presence,
              }.compact,
            ) + "\n",
            mode: "w",
            encoding: Encoding::UTF_8,
          )
          provenance_path.to_s
        end

        def provenance_path_for(skill_name)
          @workspace_root.join(".state", "skills", "#{skill_name}.json").to_s
        end

        def restore_provenance_state!(provenance_restore_state)
          provenance_restore_state.each do |path, contents|
            target = Pathname.new(path)
            if contents.nil?
              @file_utils.rm_rf(target) if target.exist?
            else
              @file_utils.mkdir_p(target.dirname)
              File.binwrite(target, contents)
            end
          end
        end

        def timestamp_token
          @timestamp_token ||= Time.current.utc.strftime("%Y%m%dT%H%M%S%6NZ")
        end
      end
    end
  end
end
