require "yaml"

module Agents
  class Loader
    DEFAULT_TIMEOUT_S = 5

    Loaded = Data.define(:runtime_surface_config, :runtime_surface_status, :manifest)

    def initialize(base_dir:, timeout_s: DEFAULT_TIMEOUT_S)
      @base_dir = Pathname.new(base_dir.to_s)
      @timeout_s = timeout_s
    end

    def load
      Timeout.timeout(@timeout_s) do
        agent_yml = safe_yaml("agent.yml")
        runtime_surface = resolve_runtime_surface(agent_yml)

        Loaded.new(
          runtime_surface_config: runtime_surface.fetch(:config),
          runtime_surface_status: runtime_surface.fetch(:status),
          manifest: data_hash(agent_yml),
        )
      end
    rescue Timeout::Error
      Loaded.new(
        runtime_surface_config: Cybros::AgentProfileConfig.default_runtime_surface_metadata,
        runtime_surface_status: "missing",
        manifest: {},
      )
    end

    private

      def resolve_runtime_surface(agent_yml)
        data = agent_yml.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(agent_yml) : {}
        present = data.key?("runtime_surface")
        raw = present ? data.fetch("runtime_surface", nil) : nil

        {
          config: Cybros::AgentProfileConfig.normalize_runtime_surface_metadata(raw),
          status: Cybros::AgentProfileConfig.runtime_surface_status(raw, present: present),
        }
      end

      def data_hash(value)
        value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
      end

      def safe_yaml(rel)
        raw = safe_file_text(rel)
        return {} if raw.strip.empty?

        parsed = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: false)
        parsed.is_a?(Hash) ? parsed : {}
      rescue Psych::Exception
        {}
      end

      def safe_file_text(rel)
        path = safe_join(@base_dir, rel)
        return "" unless path&.file?

        path.read
      rescue Errno::EACCES, Errno::ENOENT, IOError
        ""
      end

      def safe_join(root, rel)
        root = Pathname.new(root.to_s)
        candidate = root.join(rel.to_s)
        expanded = candidate.expand_path
        return nil unless expanded.to_s.start_with?(root.expand_path.to_s + File::SEPARATOR) || expanded == root.expand_path

        expanded
      end
  end
end
