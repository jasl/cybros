module Agents
  class SkillsStoreBuilder
    DUPLICATE_SKILL_CODE = "cybros.agent_runtime.skills_name_collision".freeze
    SNAPSHOT_MAX_BODY_BYTES = AgentCore::Resources::Skills::Tools::DEFAULT_MAX_BODY_BYTES
    SNAPSHOT_MAX_FILE_BYTES = AgentCore::Resources::Skills::Tools::DEFAULT_MAX_FILE_BYTES

    class SnapshotStore < AgentCore::Resources::Skills::Store
      def self.build_from(store)
        entries = {}

        store.list_skills.each do |meta|
          skill = store.load_skill(name: meta.name, max_bytes: SNAPSHOT_MAX_BODY_BYTES)
          file_bytes = {}

          skill.files_index.each_value do |paths|
            Array(paths).each do |rel_path|
              file_bytes[rel_path] = store.read_skill_file_bytes(name: meta.name, rel_path: rel_path, max_bytes: SNAPSHOT_MAX_FILE_BYTES)
            end
          end

          entries[meta.name] = {
            meta: skill.meta,
            body_markdown: skill.body_markdown.dup,
            body_truncated: skill.body_truncated == true,
            files_index: deep_dup_files_index(skill.files_index),
            file_bytes: file_bytes.transform_values(&:dup).freeze,
          }.freeze
        end

        new(entries:)
      end

      def initialize(entries:)
        @entries = entries.freeze
        @metas = @entries.values.map { |entry| entry.fetch(:meta) }.sort_by(&:name).freeze
      end

      def list_skills
        @metas
      end

      def load_skill(name:, max_bytes: nil)
        entry = fetch_entry!(name)
        max_bytes = normalize_positive_integer(max_bytes, default: SNAPSHOT_MAX_BODY_BYTES, code: "agent_core.skills.file_system_store.max_bytes_must_be_positive")
        body_markdown = entry.fetch(:body_markdown)
        body_truncated = entry.fetch(:body_truncated)

        if body_markdown.bytesize > max_bytes
          body_markdown = AgentCore::Utils.truncate_utf8_bytes(body_markdown, max_bytes: max_bytes)
          body_truncated = true
        end

        AgentCore::Resources::Skills::Skill.new(
          meta: entry.fetch(:meta),
          body_markdown: body_markdown,
          body_truncated: body_truncated,
          files_index: deep_dup_files_index(entry.fetch(:files_index)),
        )
      end

      def read_skill_file(name:, rel_path:, max_bytes: SNAPSHOT_MAX_FILE_BYTES)
        bytes = read_skill_file_bytes(name: name, rel_path: rel_path, max_bytes: max_bytes)
        normalize_utf8(bytes)
      end

      def read_skill_file_bytes(name:, rel_path:, max_bytes: SNAPSHOT_MAX_FILE_BYTES)
        entry = fetch_entry!(name)
        normalized_path = rel_path.to_s
        bytes = entry.fetch(:file_bytes).fetch(normalized_path) do
          AgentCore::ValidationError.raise!(
            "Skill file not found: #{normalized_path}",
            code: "agent_core.skills.file_system_store.skill_file_not_found",
            details: { rel_path: normalized_path },
          )
        end

        max_bytes = normalize_positive_integer(max_bytes, default: SNAPSHOT_MAX_FILE_BYTES, code: "agent_core.skills.tools.max_file_bytes_must_be_positive")
        bytes.byteslice(0, max_bytes).to_s.b
      end

      private

        def fetch_entry!(name)
          entry = @entries[name.to_s]
          return entry if entry

          AgentCore::ValidationError.raise!(
            "Unknown skill: #{name}",
            code: "agent_core.skills.file_system_store.unknown_skill",
            details: { skill_name: name.to_s },
          )
        end

        def normalize_positive_integer(value, default:, code:)
          candidate = value.nil? ? default : Integer(value)
          AgentCore::ValidationError.raise!(
            "max_bytes must be positive",
            code: code,
            details: { max_bytes: candidate },
          ) if candidate <= 0

          candidate
        end

        def normalize_utf8(bytes)
          text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
          return text if text.valid_encoding?

          text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
          bytes.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        end

        def self.deep_dup_files_index(files_index)
          files_index.each_with_object({}) do |(group, paths), out|
            out[group] = Array(paths).map(&:dup)
          end.freeze
        end
      class << self
        alias_method :deep_dup_files_index_for_snapshot, :deep_dup_files_index
      end

        def deep_dup_files_index(files_index)
          self.class.deep_dup_files_index_for_snapshot(files_index)
        end
    end

    def self.build(agent:, platform_skill_dirs: default_platform_skill_dirs)
      new(agent:, platform_skill_dirs: platform_skill_dirs).build
    end

    def self.default_platform_skill_dirs
      [Rails.root.join("skills").to_s]
    end

    def initialize(agent:, platform_skill_dirs: self.class.default_platform_skill_dirs)
      @agent = agent
      @platform_skill_dirs = Array(platform_skill_dirs)
    end

    def build
      dirs = resolved_dirs
      return nil if dirs.empty?

      store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: dirs, strict: true)
      SnapshotStore.build_from(store)
    rescue AgentCore::ValidationError => e
      raise_duplicate_collision!(e) if e.code == "agent_core.skills.file_system_store.duplicate_skill_name"
      raise
    end

    private

      attr_reader :agent, :platform_skill_dirs

      def resolved_dirs
        dirs = platform_skill_dirs.filter_map do |dir|
          path = Pathname.new(dir.to_s)
          path.to_s if path.directory?
        end

        agent_skills_dir = agent&.workspace_root_path&.join("skills")
        dirs << agent_skills_dir.to_s if agent_skills_dir&.directory?
        dirs.uniq
      end

      def raise_duplicate_collision!(error)
        details = error.details.is_a?(Hash) ? error.details : {}

        AgentCore::ValidationError.raise!(
          "Agent-local skills cannot override platform skills.",
          code: DUPLICATE_SKILL_CODE,
          details: {
            skill_name: details[:skill_name] || details["skill_name"],
            platform_skill_dirs: platform_skill_dirs.map(&:to_s),
            agent_id: agent&.id,
          },
        )
      end
  end
end
