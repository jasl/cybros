require_relative "skill_installation/source_fetcher"
require_relative "skill_installation/manifest"
require_relative "skill_installation/provenance_store"

module Agents
  class SkillInstallationService
    PLATFORM_COLLISION_CODE = "cybros.skills_install.destination_conflicts_with_platform_skill".freeze
    INVALID_SKILL_ROOT_CODE = "cybros.skills_install.invalid_skill_root".freeze
    INVALID_SKILL_ENTRY_CODE = "cybros.skills_install.invalid_skill_entry".freeze
    SOURCE_HASH_MISMATCH_CODE = "cybros.skills_install.source_hash_mismatch".freeze
    DESTINATION_EXISTS_CODE = "cybros.skills_install.destination_exists".freeze
    INSTALL_AS_NOT_ALLOWED_CODE = "cybros.skills_install.install_as_not_allowed".freeze
    SKILL_NAME_MISMATCH_CODE = "cybros.skills_install.skill_name_mismatch".freeze
    DUPLICATE_INSTALL_NAME_CODE = "cybros.skills_install.duplicate_install_name".freeze

    def self.prepare(...)
      new(...).prepare
    end

    def self.install(...)
      new(...).install
    end

    def initialize(
      agent:,
      source_kind:,
      catalog: nil,
      catalog_entry: nil,
      repo: nil,
      ref: nil,
      path: nil,
      install_as: nil,
      replace: false,
      expected_sha256: nil,
      source_fetcher: nil,
      platform_skill_dirs: Agents::SkillsStoreBuilder.default_platform_skill_dirs,
      file_utils: FileUtils,
      provenance_store: nil
    )
      @agent = agent
      @source_kind = source_kind.to_s
      @catalog = catalog
      @catalog_entry = catalog_entry
      @repo = repo
      @ref = ref
      @path = path
      @install_as = install_as
      @replace = replace == true
      @expected_sha256 = expected_sha256.to_s.strip.presence
      @platform_skill_dirs = Array(platform_skill_dirs)
      @source_fetcher = source_fetcher || Agents::SkillInstallation::SourceFetcher.new
      @file_utils = file_utils
      @provenance_store = provenance_store || Agents::SkillInstallation::ProvenanceStore.new(agent: @agent)
    end

    def prepare
      validate_repo_root_batch_arguments!

      install_name = resolved_install_name
      unless repo_root_batch_mode?
        validate_platform_collision!(install_name)
        validate_destination!(install_name)
      end

      staged = @source_fetcher.fetch!(
        source_kind: @source_kind,
        catalog: @catalog,
        catalog_entry: @catalog_entry,
        repo: normalized_repo,
        ref: @ref,
        path: @path,
      )

      stage_root = Pathname.new(staged.fetch(:stage_root)).expand_path
      skill_root = Pathname.new(staged.fetch(:skill_root)).expand_path
      prepared_repo = staged[:repo].presence || normalized_repo

      if repo_root_batch_mode?
        return {
          status: "prepared",
          mode: "repo_root_batch",
          source_kind: @source_kind,
          replace: @replace,
          agent_id: @agent&.id,
          repo: prepared_repo,
          ref: @ref,
          path: nil,
          stage_root: stage_root.to_s,
          skill_root: skill_root.to_s,
          candidates: discover_repo_root_candidates!(stage_root:, source_root: skill_root),
        }
      end

      validate_skill_root!(stage_root:, skill_root:)

      manifest = Agents::SkillInstallation::Manifest.build(skill_root: skill_root)
      validate_expected_sha256!(manifest.fetch(:package_sha256))

      {
        status: "prepared",
        mode: "single_skill",
        source_kind: @source_kind,
        install_name: install_name,
        replace: @replace,
        agent_id: @agent&.id,
        catalog: @catalog,
        catalog_entry: @catalog_entry,
        repo: prepared_repo,
        ref: @ref,
        path: @path,
        stage_root: stage_root.to_s,
        skill_root: skill_root.to_s,
        manifest: manifest,
        source_sha256: manifest.fetch(:package_sha256),
      }
    end

    def install
      prepared = prepare
      return install_repo_root_batch(prepared) if prepared.fetch(:mode) == "repo_root_batch"

      live_root = @agent.workspace_root_path.join("skills")
      live_path = live_root.join(prepared.fetch(:install_name))
      temp_path = live_root.join(".install-#{prepared.fetch(:install_name)}-#{SecureRandom.hex(4)}")
      backup_root = @agent.workspace_root_path.join(".state", "skills", "backups")

      @file_utils.mkdir_p(live_root)
      @file_utils.cp_r(prepared.fetch(:skill_root), temp_path, preserve: true)

      snapshot_path = nil
      backup_path = nil

      begin
        if live_path.exist?
          snapshot_path = snapshot_skill!(skill_name: prepared.fetch(:install_name), live_path: live_path)
          @file_utils.mkdir_p(backup_root)
          backup_path = backup_root.join("#{prepared.fetch(:install_name)}-#{timestamp_token}")
          @file_utils.mv(live_path, backup_path)
        end

        @file_utils.mv(temp_path, live_path)

        installed_manifest = Agents::SkillInstallation::Manifest.build(skill_root: live_path)
        provenance_path =
          @provenance_store.write!(
            skill_name: prepared.fetch(:install_name),
            source_kind: prepared.fetch(:source_kind),
            catalog: prepared[:catalog],
            catalog_entry: prepared[:catalog_entry],
            repo: prepared[:repo],
            ref: prepared[:ref],
            path: prepared[:path],
            source_path: prepared_source_path(prepared),
            source_sha256: prepared.fetch(:source_sha256),
            installed_sha256: installed_manifest.fetch(:package_sha256),
            snapshot_path: snapshot_path,
            install_mode: prepared.fetch(:mode),
            batch_installed_count: 1,
            batch_install_names: [prepared.fetch(:install_name)],
          )
        Agents::SkillsStoreBuilder.mark_dirty!(agent: @agent)

        @file_utils.rm_rf(backup_path) if backup_path&.exist?

        build_install_result(
          prepared: prepared,
          installed_skills: [
            {
              installed_name: prepared.fetch(:install_name),
              source_path: prepared_source_path(prepared),
              live_path: live_path.to_s,
              source_sha256: prepared.fetch(:source_sha256),
              installed_sha256: installed_manifest.fetch(:package_sha256),
              snapshot_path: snapshot_path,
              provenance_path: provenance_path,
            }.compact,
          ],
        )
      rescue StandardError
        @file_utils.rm_rf(live_path) if live_path.exist? && backup_path&.exist?
        @file_utils.mv(backup_path, live_path) if backup_path&.exist? && !live_path.exist?
        @file_utils.rm_rf(temp_path) if temp_path.exist?
        raise
      ensure
        @file_utils.rm_rf(temp_path) if temp_path.exist?
      end
    end

    private

      def normalized_repo
        return @repo unless @source_kind == "github"

        Agents::SkillInstallation::SourceFetcher.normalize_github_repo(@repo)
      end

      def repo_root_batch_mode?
        @source_kind == "github" && @repo.to_s.strip.present? && @path.to_s.strip.blank?
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
          AgentCore::ValidationError.raise!(
            "Fetched repository root did not contain any installable skills.",
            code: INVALID_SKILL_ROOT_CODE,
            details: {
              repo: normalized_repo,
              stage_root: stage_root.to_s,
              skill_root: source_root.to_s,
            }.compact,
          )
        end

        candidates =
          candidate_roots.map do |candidate_root|
            normalize_repo_root_candidate(stage_root:, source_root:, candidate_root:)
          end

        validate_repo_root_batch_candidates!(candidates)
        candidates
      end

      def preferred_repo_root_candidate_roots(source_root)
        discover_skill_roots(
          source_root,
          patterns: [
            "skills/*/SKILL.md",
            "skills/*/*/SKILL.md",
            "skills/.system/*/SKILL.md",
          ],
        )
      end

      def fallback_repo_root_candidate_roots(source_root)
        discover_skill_roots(
          source_root,
          patterns: [
            "SKILL.md",
            "*/SKILL.md",
            "*/*/SKILL.md",
          ],
        )
      end

      def discover_skill_roots(source_root, patterns:)
        Array(patterns).flat_map do |pattern|
          Dir.glob(source_root.join(pattern).to_s)
            .select { |path| File.file?(path) }
            .map { |path| Pathname.new(path).dirname.expand_path }
        end.uniq.sort_by do |candidate_root|
          candidate_root.relative_path_from(source_root).to_s.tr(File::SEPARATOR, "/")
        end
      end

      def normalize_repo_root_candidate(stage_root:, source_root:, candidate_root:)
        validate_skill_root!(stage_root:, skill_root: candidate_root)

        install_name = candidate_root.basename.to_s
        validate_repo_root_candidate_name!(candidate_root:, install_name:)

        manifest = Agents::SkillInstallation::Manifest.build(skill_root: candidate_root)
        live_path = @agent&.workspace_root_path&.join("skills", install_name)

        {
          install_name: install_name,
          source_path: candidate_root.relative_path_from(source_root).to_s.tr(File::SEPARATOR, "/"),
          skill_root: candidate_root.to_s,
          replace: live_path&.exist? && @replace,
          manifest: manifest,
          source_sha256: manifest.fetch(:package_sha256),
        }
      end

      def validate_repo_root_batch_arguments!
        return unless repo_root_batch_mode?
        return if @install_as.to_s.strip.blank?

        AgentCore::ValidationError.raise!(
          "Repo-root batch installs do not support install_as.",
          code: INSTALL_AS_NOT_ALLOWED_CODE,
          details: {
            install_as: @install_as.to_s,
          },
        )
      end

      def validate_repo_root_candidate_name!(candidate_root:, install_name:)
        frontmatter, =
          AgentCore::Resources::Skills::Frontmatter.parse(
            File.read(candidate_root.join("SKILL.md")),
            path: candidate_root.join("SKILL.md").to_s,
            strict: true,
          )

        return if frontmatter.fetch(:name) == install_name

        AgentCore::ValidationError.raise!(
          "Repo-root candidate skill names must match their directory names.",
          code: SKILL_NAME_MISMATCH_CODE,
          details: {
            skill_root: candidate_root.to_s,
            install_name: install_name,
            declared_name: frontmatter.fetch(:name),
          },
        )
      rescue AgentCore::ValidationError => e
        if e.code == "agent_core.skills.frontmatter.invalid_frontmatter" &&
            e.details[:message].to_s.include?("skill name must match directory name")
          AgentCore::ValidationError.raise!(
            "Repo-root candidate skill names must match their directory names.",
            code: SKILL_NAME_MISMATCH_CODE,
            details: {
              skill_root: candidate_root.to_s,
              install_name: install_name,
            },
          )
        end

        raise
      end

      def validate_repo_root_batch_candidates!(candidates)
        duplicates = candidates.group_by { |candidate| candidate.fetch(:install_name) }.select { |_name, entries| entries.length > 1 }
        if duplicates.present?
          install_name, entries = duplicates.sort_by { |name, _entries| name }.first
          AgentCore::ValidationError.raise!(
            "Repo-root batch installs may not include duplicate install names.",
            code: DUPLICATE_INSTALL_NAME_CODE,
            details: {
              install_name: install_name,
              source_paths: entries.map { |entry| entry.fetch(:source_path) },
            },
          )
        end

        candidates.each do |candidate|
          install_name = candidate.fetch(:install_name)
          validate_platform_collision!(install_name)
          validate_destination!(install_name)
        end
      end

      def validate_platform_collision!(install_name)
        return if install_name.blank?
        return unless platform_skill_names.include?(install_name)

        AgentCore::ValidationError.raise!(
          "Installed skills may not override platform skills.",
          code: PLATFORM_COLLISION_CODE,
          details: {
            skill_name: install_name,
            agent_id: @agent&.id,
          }.compact,
        )
      end

      def validate_destination!(install_name)
        return if install_name.blank? || @replace
        return unless @agent&.workspace_root_path&.join("skills", install_name)&.exist?

        AgentCore::ValidationError.raise!(
          "Destination skill already exists.",
          code: DESTINATION_EXISTS_CODE,
          details: {
            skill_name: install_name,
            agent_id: @agent&.id,
          }.compact,
        )
      end

      def validate_skill_root!(stage_root:, skill_root:)
        validate_staged_directory!(stage_root:, target_root: skill_root)

        return if skill_root.join("SKILL.md").file?

        AgentCore::ValidationError.raise!(
          "Fetched skill root must contain SKILL.md.",
          code: INVALID_SKILL_ROOT_CODE,
          details: {
            stage_root: stage_root.to_s,
            skill_root: skill_root.to_s,
          },
        )
      end

      def validate_staged_directory!(stage_root:, target_root:)
        unless stage_root.directory? && target_root.directory?
          AgentCore::ValidationError.raise!(
            "Fetched skill source did not resolve to a valid directory.",
            code: INVALID_SKILL_ROOT_CODE,
          )
        end

        normalized_stage_root = stage_root.expand_path.to_s
        normalized_target_root = target_root.expand_path.to_s
        unless normalized_target_root == normalized_stage_root || normalized_target_root.start_with?(normalized_stage_root + File::SEPARATOR)
          AgentCore::ValidationError.raise!(
            "Fetched skill path escapes the staged source root.",
            code: INVALID_SKILL_ROOT_CODE,
            details: {
              stage_root: stage_root.to_s,
              skill_root: target_root.to_s,
            },
          )
        end
      end

      def validate_expected_sha256!(package_sha256)
        return if @expected_sha256.blank?
        return if ActiveSupport::SecurityUtils.secure_compare(package_sha256, @expected_sha256)

        AgentCore::ValidationError.raise!(
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

            AgentCore::Resources::Skills::FileSystemStore.new(dirs: [root.to_s], strict: true)
              .list_skills
              .map(&:name)
          end
      end

      def snapshot_skill!(skill_name:, live_path:)
        snapshot_root = @agent.workspace_root_path.join(".history", "skills", skill_name, timestamp_token)
        @file_utils.mkdir_p(snapshot_root.dirname)
        @file_utils.cp_r(live_path, snapshot_root, preserve: true)
        snapshot_root.to_s
      end

      def prepared_source_path(prepared)
        prepared[:path].presence || prepared[:catalog_entry].presence || prepared.fetch(:install_name)
      end

      def install_repo_root_batch(prepared)
        live_root = @agent.workspace_root_path.join("skills")
        backup_root = @agent.workspace_root_path.join(".state", "skills", "backups")
        batch_install_names = prepared.fetch(:candidates).map { |candidate| candidate.fetch(:install_name) }
        provenance_restore_state = {}

        plans =
          prepared.fetch(:candidates).map do |candidate|
            {
              candidate: candidate,
              live_path: live_root.join(candidate.fetch(:install_name)),
              temp_path: live_root.join(".install-#{candidate.fetch(:install_name)}-#{SecureRandom.hex(4)}"),
              backup_path: nil,
              snapshot_path: nil,
              moved_to_backup: false,
              promoted: false,
            }
          end

        @file_utils.mkdir_p(live_root)
        plans.each do |plan|
          @file_utils.cp_r(plan.fetch(:candidate).fetch(:skill_root), plan.fetch(:temp_path), preserve: true)
        end

        begin
          plans.each do |plan|
            next unless plan.fetch(:live_path).exist?

            plan[:snapshot_path] = snapshot_skill!(skill_name: plan.fetch(:candidate).fetch(:install_name), live_path: plan.fetch(:live_path))
            @file_utils.mkdir_p(backup_root)
            plan[:backup_path] = backup_root.join("#{plan.fetch(:candidate).fetch(:install_name)}-#{timestamp_token}")
            @file_utils.mv(plan.fetch(:live_path), plan.fetch(:backup_path))
            plan[:moved_to_backup] = true
          end

          plans.each do |plan|
            @file_utils.mv(plan.fetch(:temp_path), plan.fetch(:live_path))
            plan[:promoted] = true
          end

          installed_skills =
            plans.map do |plan|
              candidate = plan.fetch(:candidate)
              installed_manifest = Agents::SkillInstallation::Manifest.build(skill_root: plan.fetch(:live_path))
              restore_key = provenance_path_for(candidate.fetch(:install_name))
              provenance_restore_state[restore_key] =
                if Pathname.new(restore_key).exist?
                  File.binread(restore_key)
                else
                  nil
                end

              provenance_path =
                @provenance_store.write!(
                  skill_name: candidate.fetch(:install_name),
                  source_kind: prepared.fetch(:source_kind),
                  catalog: prepared[:catalog],
                  catalog_entry: prepared[:catalog_entry],
                  repo: prepared[:repo],
                  ref: prepared[:ref],
                  path: prepared[:path],
                  source_path: candidate.fetch(:source_path),
                  source_sha256: candidate.fetch(:source_sha256),
                  installed_sha256: installed_manifest.fetch(:package_sha256),
                  snapshot_path: plan[:snapshot_path],
                  install_mode: prepared.fetch(:mode),
                  batch_installed_count: plans.length,
                  batch_install_names: batch_install_names,
                )

              {
                installed_name: candidate.fetch(:install_name),
                source_path: candidate.fetch(:source_path),
                live_path: plan.fetch(:live_path).to_s,
                source_sha256: candidate.fetch(:source_sha256),
                installed_sha256: installed_manifest.fetch(:package_sha256),
                snapshot_path: plan[:snapshot_path],
                provenance_path: provenance_path,
              }.compact
            end

          Agents::SkillsStoreBuilder.mark_dirty!(agent: @agent)
          plans.each { |plan| @file_utils.rm_rf(plan[:backup_path]) if plan[:backup_path]&.exist? }

          build_install_result(prepared:, installed_skills:)
        rescue StandardError
          plans.each do |plan|
            if plan[:promoted]
              @file_utils.rm_rf(plan.fetch(:live_path)) if plan.fetch(:live_path).exist?
            end
            if plan[:moved_to_backup]
              @file_utils.mv(plan.fetch(:backup_path), plan.fetch(:live_path)) if plan.fetch(:backup_path)&.exist? && !plan.fetch(:live_path).exist?
            end
          end
          restore_provenance_state!(provenance_restore_state)
          raise
        ensure
          plans.each { |plan| @file_utils.rm_rf(plan.fetch(:temp_path)) if plan.fetch(:temp_path).exist? }
        end
      end

      def build_install_result(prepared:, installed_skills:)
        {
          mode: prepared.fetch(:mode),
          source_kind: prepared.fetch(:source_kind),
          catalog: prepared[:catalog],
          catalog_entry: prepared[:catalog_entry],
          repo: prepared[:repo],
          ref: prepared[:ref],
          refresh_effective_on_next_top_level_turn: true,
          installed_count: installed_skills.length,
          installed_skills: installed_skills,
        }.compact
      end

      def provenance_path_for(skill_name)
        @agent.workspace_root_path.join(".state", "skills", "#{skill_name}.json").to_s
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
