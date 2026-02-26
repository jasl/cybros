require "yaml"

module AgentPrograms
  class Loader
    DEFAULT_TIMEOUT_S = 5

    Loaded =
      Data.define(
        :agent_yml,
        :agent_md,
        :soul_md,
        :user_md,
        :system_md_liquid,
      )

    def initialize(base_dir:, timeout_s: DEFAULT_TIMEOUT_S)
      @base_dir = Pathname.new(base_dir.to_s)
      @timeout_s = timeout_s
    end

    def load
      Timeout.timeout(@timeout_s) do
        Loaded.new(
          agent_yml: safe_yaml("agent.yml"),
          agent_md: safe_text("AGENT.md"),
          soul_md: safe_text("SOUL.md"),
          user_md: safe_text("USER.md"),
          system_md_liquid: safe_text("prompts/system.md.liquid"),
        )
      end
    rescue StandardError
      Loaded.new(agent_yml: {}, agent_md: "", soul_md: "", user_md: "", system_md_liquid: "")
    end

    private

      def safe_yaml(rel)
        raw = safe_text(rel)
        return {} if raw.strip.empty?

        parsed = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: false)
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end

      def safe_text(rel)
        path = safe_join(@base_dir, rel)
        return "" unless path&.file?

        path.read
      rescue StandardError
        ""
      end

      def safe_join(root, rel)
        root = Pathname.new(root.to_s)
        candidate = root.join(rel.to_s)
        expanded = candidate.expand_path
        return nil unless expanded.to_s.start_with?(root.expand_path.to_s + File::SEPARATOR) || expanded == root.expand_path

        expanded
      rescue StandardError
        nil
      end
  end
end
